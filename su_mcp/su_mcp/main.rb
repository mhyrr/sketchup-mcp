require 'sketchup'
require 'json'
require 'socket'
require 'fileutils'

puts "MCP Extension loading..."
SKETCHUP_CONSOLE.show rescue nil

module SU_MCP
  class Server
    def initialize
      @port = 9876
      @server = nil
      @running = false
      @timer_id = nil

      # Try multiple ways to show console
      begin
        SKETCHUP_CONSOLE.show
      rescue
        begin
          Sketchup.send_action("showRubyPanel:")
        rescue
          UI.start_timer(0) { SKETCHUP_CONSOLE.show }
        end
      end
    end

    def log(msg)
      begin
        SKETCHUP_CONSOLE.write("MCP: #{msg}\n")
      rescue
        puts "MCP: #{msg}"
      end
      STDOUT.flush
    end

    def start
      return if @running

      begin
        log "Starting server on localhost:#{@port}..."

        @server = TCPServer.new('127.0.0.1', @port)
        log "Server created on port #{@port}"

        @running = true

        @timer_id = UI.start_timer(0.1, true) {
          begin
            if @running
              # Check for connection
              ready = IO.select([@server], nil, nil, 0)
              if ready
                log "Connection waiting..."
                client_socket = @server.accept_nonblock # Renamed for clarity
                log "Client socket accepted: #{client_socket.inspect}"

                data_string = nil
                pre_parse_request_id = nil

                # Check if the client socket is ready for reading with a short timeout
                # This prevents client_socket.gets from blocking indefinitely.
                ready_to_read, _, _ = IO.select([client_socket], nil, nil, 0.05) # 50ms timeout


                if ready_to_read && ready_to_read.include?(client_socket)
                  begin
                    # Read the line, this should now be quick or return nil if client closed
                    data_string = client_socket.gets # `gets` reads until newline or EOF
                    log "Raw data string from socket: #{data_string.inspect}"

                    if data_string && data_string =~ /"id":\s*(\d+)/
                      pre_parse_request_id = $1.to_i
                      log "Pre-parse regex found request ID: #{pre_parse_request_id}"
                    elsif data_string && data_string =~ /"id":\s*"([^"]*)"/ # Also check for string ID via regex
                      pre_parse_request_id = $1
                      log "Pre-parse regex found string request ID: #{pre_parse_request_id}"
                    elsif data_string && data_string.include?('"id":null') # Check for null ID via regex
                      pre_parse_request_id = nil # Explicitly nil
                      log "Pre-parse regex found null request ID"
                    end

                  rescue Errno::ECONNRESET
                    log "Connection reset by peer during client_socket.gets."
                    data_string = nil # Ensure processing is skipped
                  rescue IOError => e
                    log "IOError during client_socket.gets (e.g., socket closed before read): #{e.message}"
                    data_string = nil
                  rescue StandardError => e_gets
                    log "Unexpected error during client_socket.gets: #{e_gets.message}"
                    log e_gets.backtrace.join("\n")
                    data_string = nil
                  end
                else
                  log "Client socket not ready for reading within timeout or IO.select error."
                  # If client connected but sent nothing within the timeout, data_string remains nil.
                  # The connection will be closed at the end of this block.
                end

                if data_string && !data_string.strip.empty?
                  # Process the request
                  begin
                    # It's safer to strip whitespace (like the newline from gets) before parsing
                    stripped_data = data_string.strip
                    raw_request = JSON.parse(stripped_data)
                    log "Raw parsed request: #{raw_request.inspect}"

                    # The ID from the parsed JSON is the most reliable.
                    # Use pre_parse_request_id as a fallback if raw_request["id"] is missing,
                    # consistent with original logic for ensuring an ID for responses.
                    request_to_handle = raw_request
                    if !request_to_handle.key?("id") && !pre_parse_request_id.nil?
                      request_to_handle["id"] = pre_parse_request_id
                      log "Patched request with pre_parse_request_id for handler: #{pre_parse_request_id}"
                    end

                    log "Processed request for JSON-RPC handler: #{request_to_handle.inspect}"
                    response = handle_jsonrpc_request(request_to_handle)
                    response_json = response.to_json + "\n"

                    log "Sending response: #{response_json.strip}"
                    client_socket.write(response_json)
                    client_socket.flush
                    log "Response sent"
                  rescue JSON::ParserError => e
                    log "JSON parse error: #{e.message} on data: #{data_string.inspect}"
                    # Use pre_parse_request_id for the error response ID if parsing failed
                    error_response = {
                                       jsonrpc: "2.0",
                                       error: { code: -32700, message: "Parse error: #{e.message}" },
                                       id: pre_parse_request_id
                                     }.to_json + "\n"
                    client_socket.write(error_response)
                    client_socket.flush
                  rescue StandardError => e
                    log "Request handling error: #{e.message}"
                    log e.backtrace.join("\n")
                    # Determine ID for error response: use ID from parsed request if available, else pre_parse_request_id
                    id_for_error = (defined?(request_to_handle) && request_to_handle && request_to_handle.key?("id")) ? request_to_handle["id"] : pre_parse_request_id
                    error_response = {
                                       jsonrpc: "2.0",
                                       error: { code: -32603, message: "Internal error: #{e.message}" },
                                       id: id_for_error
                                     }.to_json + "\n"
                    client_socket.write(error_response)
                    client_socket.flush
                  end
                elsif ready_to_read && ready_to_read.include?(client_socket) && (data_string.nil? || (data_string && data_string.strip.empty?))
                  # This case means client_socket.gets returned nil (EOF) or an empty/whitespace string.
                  if data_string.nil?
                    log "Client closed connection (EOF detected by gets returning nil)."
                  else
                    log "Received empty or whitespace-only data from client. Closing connection."
                  end
                else
                  # IO.select timed out, or client_socket wasn't in ready_to_read. No data received.
                  log "No data received from client socket, or socket not ready. Closing connection."
                end

                client_socket.close
                log "Client socket closed"
              end
            end
          rescue IO::WaitReadable
            # Normal for accept_nonblock
          rescue StandardError => e
            log "Timer error: #{e.message}"
            log e.backtrace.join("\n")
          end
        }

        log "Server started and listening"

      rescue StandardError => e
        log "Error: #{e.message}"
        log e.backtrace.join("\n")
        stop
      end
    end

    def stop
      log "Stopping server..."
      @running = false

      if @timer_id
        UI.stop_timer(@timer_id)
        @timer_id = nil
      end

      @server.close if @server
      @server = nil
      log "Server stopped"
    end

    private

    def handle_jsonrpc_request(request)
      log "Handling JSONRPC request: #{request.inspect}"

      # Handle direct command format (for backward compatibility)
      if request["command"]
        tool_request = {
          "method" => "tools/call",
          "params" => {
            "name" => request["command"],
            "arguments" => request["parameters"]
          },
          "jsonrpc" => request["jsonrpc"] || "2.0",
          "id" => request["id"]
        }
        log "Converting to tool request: #{tool_request.inspect}"
        return handle_tool_call(tool_request)
      end

      # Handle jsonrpc format
      case request["method"]
      when "tools/call"
        handle_tool_call(request)
      when "resources/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: {
            resources: list_resources,
            success: true
          },
          id: request["id"]
        }
      when "prompts/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: {
            prompts: [],
            success: true
          },
          id: request["id"]
        }
      else
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          error: {
            code: -32601,
            message: "Method not found",
            data: { success: false }
          },
          id: request["id"]
        }
      end
    end

    def list_resources
      model = Sketchup.active_model
      return [] unless model

      model.entities.map do |entity|
        {
          id: entity.entityID,
          type: entity.typename.downcase
        }
      end
    end

    def handle_tool_call(request)
      log "Handling tool call: #{request.inspect}"
      tool_name = request["params"]["name"]
      args = request["params"]["arguments"]

      begin
        result = case tool_name
        when "create_component"
          create_component(args)
        when "delete_component"
          delete_component(args)
        when "transform_component"
          transform_component(args)
        when "get_selection"
          get_selection
        when "export", "export_scene"
          export_scene(args)
        when "set_material"
          set_material(args)
        when "boolean_operation"
          boolean_operation(args)
        when "chamfer_edges"
          chamfer_edges(args)
        when "fillet_edges"
          fillet_edges(args)
        when "create_mortise_tenon"
          create_mortise_tenon(args)
        when "create_dovetail"
          create_dovetail(args)
        when "create_finger_joint"
          create_finger_joint(args)
        when "eval_ruby"
          eval_ruby(args)
        else
          raise "Unknown tool: #{tool_name}"
        end

        log "Tool call result: #{result.inspect}"
        if result[:success]
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            result: {
              content: [{ type: "text", text: result[:result] || "Success" }],
              isError: false,
              success: true,
              resourceId: result[:id]
            },
            id: request["id"]
          }
          log "Sending success response: #{response.inspect}"
          response
        else
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            error: {
              code: -32603,
              message: "Operation failed",
              data: { success: false }
            },
            id: request["id"]
          }
          log "Sending error response: #{response.inspect}"
          response
        end
      rescue StandardError => e
        log "Tool call error: #{e.message}"
        response = {
          jsonrpc: request["jsonrpc"] || "2.0",
          error: {
            code: -32603,
            message: e.message,
            data: { success: false }
          },
          id: request["id"]
        }
        log "Sending error response: #{response.inspect}"
        response
      end
    end

    def create_component(params)
      log "Creating component with params: #{params.inspect}"
      model = Sketchup.active_model
      log "Got active model: #{model.inspect}"
      entities = model.active_entities
      log "Got active entities: #{entities.inspect}"

      pos = params["position"] || [0,0,0]
      dims = params["dimensions"] || [1,1,1]

      case params["type"]
      when "cube"
        log "Creating cube at position #{pos.inspect} with dimensions #{dims.inspect}"

        begin
          group = entities.add_group
          log "Created group: #{group.inspect}"

          face = group.entities.add_face(
            [pos[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1] + dims[1], pos[2]],
            [pos[0], pos[1] + dims[1], pos[2]]
          )
          log "Created face: #{face.inspect}"

          face.pushpull(dims[2])
          log "Pushed/pulled face by #{dims[2]}"

          result = {
            id: group.entityID,
            success: true
          }
          log "Returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error in create_component: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cylinder"
        log "Creating cylinder at position #{pos.inspect} with dimensions #{dims.inspect}"

        begin
          # Create a group to contain the cylinder
          group = entities.add_group

          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]

          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]

          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []

          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end

          # Create the circular face
          face = group.entities.add_face(circle_points)

          # Extrude the face to create the cylinder
          face.pushpull(height)

          result = {
            id: group.entityID,
            success: true
          }
          log "Created cylinder, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cylinder: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "sphere"
        log "Creating sphere at position #{pos.inspect} with dimensions #{dims.inspect}"

        begin
          # Create a group to contain the sphere
          group = entities.add_group

          # Extract dimensions
          radius = dims[0] / 2.0
          center = [pos[0] + radius, pos[1] + radius, pos[2] + radius]

          # Use SketchUp's built-in sphere method if available
          if Sketchup::Tools.respond_to?(:create_sphere)
            Sketchup::Tools.create_sphere(center, radius, 24, group.entities)
          else
            # Fallback implementation using polygons
            # Create a UV sphere with latitude and longitude segments
            segments = 16

            # Create points for the sphere
            points = []
            for lat_i in 0..segments
              lat = Math::PI * lat_i / segments
              for lon_i in 0..segments
                lon = 2 * Math::PI * lon_i / segments
                x = center[0] + radius * Math.sin(lat) * Math.cos(lon)
                y = center[1] + radius * Math.sin(lat) * Math.sin(lon)
                z = center[2] + radius * Math.cos(lat)
                points << [x, y, z]
              end
            end

            # Create faces for the sphere (simplified approach)
            for lat_i in 0...segments
              for lon_i in 0...segments
                i1 = lat_i * (segments + 1) + lon_i
                i2 = i1 + 1
                i3 = i1 + segments + 1
                i4 = i3 + 1

                # Create a quad face
                begin
                  group.entities.add_face(points[i1], points[i2], points[i4], points[i3])
                rescue StandardError => e
                  # Skip faces that can't be created (may happen at poles)
                  log "Skipping face: #{e.message}"
                end
              end
            end
          end

          result = {
            id: group.entityID,
            success: true
          }
          log "Created sphere, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating sphere: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cone"
        log "Creating cone at position #{pos.inspect} with dimensions #{dims.inspect}"

        begin
          # Create a group to contain the cone
          group = entities.add_group

          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]

          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]
          apex = [center[0], center[1], center[2] + height]

          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []

          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end

          # Create the circular face for the base
          base = group.entities.add_face(circle_points)

          # Create the cone sides
          (0...num_segments).each do |i|
            j = (i + 1) % num_segments
            # Create a triangular face from two adjacent points on the circle to the apex
            group.entities.add_face(circle_points[i], circle_points[j], apex)
          end

          result = {
            id: group.entityID,
            success: true
          }
          log "Created cone, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cone: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      else
        raise "Unknown component type: #{params["type"]}"
      end
    end

    def delete_component(params)
      model = Sketchup.active_model

      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"

      entity = model.find_entity_by_id(id_str.to_i)

      if entity
        log "Found entity: #{entity.inspect}"
        entity.erase!
        { success: true }
      else
        raise "Entity not found"
      end
    end

    def transform_component(params)
      model = Sketchup.active_model

      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"

      entity = model.find_entity_by_id(id_str.to_i)

      if entity
        log "Found entity: #{entity.inspect}"

        # Handle position
        if params["position"]
          pos = params["position"]
          log "Transforming position to #{pos.inspect}"

          # Create a transformation to move the entity
          translation = Geom::Transformation.translation(Geom::Point3d.new(pos[0], pos[1], pos[2]))
          entity.transform!(translation)
        end

        # Handle rotation (in degrees)
        if params["rotation"]
          rot = params["rotation"]
          log "Rotating by #{rot.inspect} degrees"

          # Convert to radians
          x_rot = rot[0] * Math::PI / 180
          y_rot = rot[1] * Math::PI / 180
          z_rot = rot[2] * Math::PI / 180

          # Apply rotations
          if rot[0] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(1, 0, 0), x_rot)
            entity.transform!(rotation)
          end

          if rot[1] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 1, 0), y_rot)
            entity.transform!(rotation)
          end

          if rot[2] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 0, 1), z_rot)
            entity.transform!(rotation)
          end
        end

        # Handle scale
        if params["scale"]
          scale = params["scale"]
          log "Scaling by #{scale.inspect}"

          # Create a transformation to scale the entity
          center = entity.bounds.center
          scaling = Geom::Transformation.scaling(center, scale[0], scale[1], scale[2])
          entity.transform!(scaling)
        end

        { success: true, id: entity.entityID }
      else
        raise "Entity not found"
      end
    end

    def get_selection
      model = Sketchup.active_model
      selection = model.selection

      log "Getting selection, count: #{selection.length}"

      selected_entities = selection.map do |entity|
        {
          id: entity.entityID,
          type: entity.typename.downcase
        }
      end

      { success: true, entities: selected_entities }
    end

    def export_scene(params)
      log "Exporting scene with params: #{params.inspect}"
      model = Sketchup.active_model

      format = params["format"] || "skp"

      begin
        # Create a temporary directory for exports
        temp_dir = File.join(ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir, "sketchup_exports")
        FileUtils.mkdir_p(temp_dir) unless Dir.exist?(temp_dir)

        # Generate a unique filename
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        filename = "sketchup_export_#{timestamp}"

        case format.downcase
        when "skp"
          # Export as SketchUp file
          export_path = File.join(temp_dir, "#{filename}.skp")
          log "Exporting to SketchUp file: #{export_path}"
          model.save(export_path)

        when "obj"
          # Export as OBJ file
          export_path = File.join(temp_dir, "#{filename}.obj")
          log "Exporting to OBJ file: #{export_path}"

          # Check if OBJ exporter is available
          if Sketchup.require("sketchup.rb")
            options = {
              :triangulated_faces => true,
              :double_sided_faces => true,
              :edges => false,
              :texture_maps => true
            }
            model.export(export_path, options)
          else
            raise "OBJ exporter not available"
          end

        when "dae"
          # Export as COLLADA file
          export_path = File.join(temp_dir, "#{filename}.dae")
          log "Exporting to COLLADA file: #{export_path}"

          # Check if COLLADA exporter is available
          if Sketchup.require("sketchup.rb")
            options = { :triangulated_faces => true }
            model.export(export_path, options)
          else
            raise "COLLADA exporter not available"
          end

        when "stl"
          # Export as STL file
          export_path = File.join(temp_dir, "#{filename}.stl")
          log "Exporting to STL file: #{export_path}"

          # Check if STL exporter is available
          if Sketchup.require("sketchup.rb")
            options = { :units => "model" }
            model.export(export_path, options)
          else
            raise "STL exporter not available"
          end

        when "png", "jpg", "jpeg"
          # Export as image
          ext = format.downcase == "jpg" ? "jpeg" : format.downcase
          export_path = File.join(temp_dir, "#{filename}.#{ext}")
          log "Exporting to image file: #{export_path}"

          # Get the current view
          view = model.active_view

          # Set up options for the export
          options = {
            :filename => export_path,
            :width => params["width"] || 1920,
            :height => params["height"] || 1080,
            :antialias => true,
            :transparent => (ext == "png")
          }

          # Export the image
          view.write_image(options)

        else
          raise "Unsupported export format: #{format}"
        end

        log "Export completed successfully to: #{export_path}"

        {
          success: true,
          path: export_path,
          format: format
        }
      rescue StandardError => e
        log "Error in export_scene: #{e.message}"
        log e.backtrace.join("\n")
        raise
      end
    end

    def set_material(params)
      log "Setting material with params: #{params.inspect}"
      model = Sketchup.active_model

      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"

      entity = model.find_entity_by_id(id_str.to_i)

      if entity
        log "Found entity: #{entity.inspect}"

        material_name = params["material"]
        log "Setting material to: #{material_name}"

        # Get or create the material
        material = model.materials[material_name]
        if !material
          # Create a new material if it doesn't exist
          material = model.materials.add(material_name)

          # Handle color specification
          case material_name.downcase
          when "red"
            material.color = Sketchup::Color.new(255, 0, 0)
          when "green"
            material.color = Sketchup::Color.new(0, 255, 0)
          when "blue"
            material.color = Sketchup::Color.new(0, 0, 255)
          when "yellow"
            material.color = Sketchup::Color.new(255, 255, 0)
          when "cyan", "turquoise"
            material.color = Sketchup::Color.new(0, 255, 255)
          when "magenta", "purple"
            material.color = Sketchup::Color.new(255, 0, 255)
          when "white"
            material.color = Sketchup::Color.new(255, 255, 255)
          when "black"
            material.color = Sketchup::Color.new(0, 0, 0)
          when "brown"
            material.color = Sketchup::Color.new(139, 69, 19)
          when "orange"
            material.color = Sketchup::Color.new(255, 165, 0)
          when "gray", "grey"
            material.color = Sketchup::Color.new(128, 128, 128)
          else
            # If it's a hex color code like "#FF0000"
            if material_name.start_with?("#") && material_name.length == 7
              begin
                r = material_name[1..2].to_i(16)
                g = material_name[3..4].to_i(16)
                b = material_name[5..6].to_i(16)
                material.color = Sketchup::Color.new(r, g, b)
              rescue
                # Default to a wood color if parsing fails
                material.color = Sketchup::Color.new(184, 134, 72)
              end
            else
              # Default to a wood color
              material.color = Sketchup::Color.new(184, 134, 72)
            end
          end
        end

        # Apply the material to the entity
        if entity.respond_to?(:material=)
          entity.material = material
        elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          # For groups and components, we need to apply to all faces
          entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
          entities.grep(Sketchup::Face).each { |face| face.material = material }
        end

        { success: true, id: entity.entityID }
      else
        raise "Entity not found"
      end
    end

    def boolean_operation(params)
      log "Performing boolean operation with params: #{params.inspect}"
      model = Sketchup.active_model

      # Get operation type
      operation_type = params["operation"]
      unless ["union", "difference", "intersection"].include?(operation_type)
        raise "Invalid boolean operation: #{operation_type}. Must be 'union', 'difference', or 'intersection'."
      end

      # Get target and tool entities
      target_id = params["target_id"].to_s.gsub('"', '')
      tool_id = params["tool_id"].to_s.gsub('"', '')

      log "Looking for target entity with ID: #{target_id}"
      target_entity = model.find_entity_by_id(target_id.to_i)

      log "Looking for tool entity with ID: #{tool_id}"
      tool_entity = model.find_entity_by_id(tool_id.to_i)

      unless target_entity && tool_entity
        missing = []
        missing << "target" unless target_entity
        missing << "tool" unless tool_entity
        raise "Entity not found: #{missing.join(', ')}"
      end

      # Ensure both entities are groups or component instances
      unless (target_entity.is_a?(Sketchup::Group) || target_entity.is_a?(Sketchup::ComponentInstance)) &&
             (tool_entity.is_a?(Sketchup::Group) || tool_entity.is_a?(Sketchup::ComponentInstance))
        raise "Boolean operations require groups or component instances"
      end

      # Create a new group to hold the result
      result_group = model.active_entities.add_group

      # Perform the boolean operation
      case operation_type
      when "union"
        log "Performing union operation"
        perform_union(target_entity, tool_entity, result_group)
      when "difference"
        log "Performing difference operation"
        perform_difference(target_entity, tool_entity, result_group)
      when "intersection"
        log "Performing intersection operation"
        perform_intersection(target_entity, tool_entity, result_group)
      end

      # Clean up original entities if requested
      if params["delete_originals"]
        target_entity.erase! if target_entity.valid?
        tool_entity.erase! if tool_entity.valid?
      end

      # Return the result
      {
        success: true,
        id: result_group.entityID
      }
    end

    def perform_union(target, tool, result_group)
      model = Sketchup.active_model

      # Create temporary copies of the target and tool
      target_copy = target.copy
      tool_copy = tool.copy

      # Get the transformation of each entity
      target_transform = target.transformation
      tool_transform = tool.transformation

      # Apply the transformations to the copies
      target_copy.transform!(target_transform)
      tool_copy.transform!(tool_transform)

      # Get the entities from the copies
      target_entities = target_copy.is_a?(Sketchup::Group) ? target_copy.entities : target_copy.definition.entities
      tool_entities = tool_copy.is_a?(Sketchup::Group) ? tool_copy.entities : tool_copy.definition.entities

      # Copy all entities from target to result
      target_entities.each do |entity|
        entity.copy(result_group.entities)
      end

      # Copy all entities from tool to result
      tool_entities.each do |entity|
        entity.copy(result_group.entities)
      end

      # Clean up temporary copies
      target_copy.erase!
      tool_copy.erase!

      # Outer shell - this will merge overlapping geometry
      result_group.entities.outer_shell
    end

    def perform_difference(target, tool, result_group)
      model = Sketchup.active_model

      # Create temporary copies of the target and tool
      target_copy = target.copy
      tool_copy = tool.copy

      # Get the transformation of each entity
      target_transform = target.transformation
      tool_transform = tool.transformation

      # Apply the transformations to the copies
      target_copy.transform!(target_transform)
      tool_copy.transform!(tool_transform)

      # Get the entities from the copies
      target_entities = target_copy.is_a?(Sketchup::Group) ? target_copy.entities : target_copy.definition.entities
      tool_entities = tool_copy.is_a?(Sketchup::Group) ? tool_copy.entities : tool_copy.definition.entities

      # Copy all entities from target to result
      target_entities.each do |entity|
        entity.copy(result_group.entities)
      end

      # Create a temporary group for the tool
      temp_tool_group = model.active_entities.add_group

      # Copy all entities from tool to temp group
      tool_entities.each do |entity|
        entity.copy(temp_tool_group.entities)
      end

      # Subtract the tool from the result
      result_group.entities.subtract(temp_tool_group.entities)

      # Clean up temporary copies and groups
      target_copy.erase!
      tool_copy.erase!
      temp_tool_group.erase!
    end

    def perform_intersection(target, tool, result_group)
      model = Sketchup.active_model

      # Create temporary copies of the target and tool
      target_copy = target.copy
      tool_copy = tool.copy

      # Get the transformation of each entity
      target_transform = target.transformation
      tool_transform = tool.transformation

      # Apply the transformations to the copies
      target_copy.transform!(target_transform)
      tool_copy.transform!(tool_transform)

      # Get the entities from the copies
      target_entities = target_copy.is_a?(Sketchup::Group) ? target_copy.entities : target_copy.definition.entities
      tool_entities = tool_copy.is_a?(Sketchup::Group) ? tool_copy.entities : tool_copy.definition.entities

      # Create temporary groups for target and tool
      temp_target_group = model.active_entities.add_group
      temp_tool_group = model.active_entities.add_group

      # Copy all entities from target and tool to temp groups
      target_entities.each do |entity|
        entity.copy(temp_target_group.entities)
      end

      tool_entities.each do |entity|
        entity.copy(temp_tool_group.entities)
      end

      # Perform the intersection
      result_group.entities.intersect_with(temp_target_group.entities, temp_tool_group.entities)

      # Clean up temporary copies and groups
      target_copy.erase!
      tool_copy.erase!
      temp_target_group.erase!
      temp_tool_group.erase!
    end

    def chamfer_edges(params)
      log "Chamfering edges with params: #{params.inspect}"
      model = Sketchup.active_model

      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"

      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end

      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Chamfer operation requires a group or component instance"
      end

      # Get the distance parameter
      distance = params["distance"] || 0.5

      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities

      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)

      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end

      # Create a new group to hold the result
      result_group = model.active_entities.add_group

      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end

      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)

      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end

      # Perform the chamfer operation
      begin
        # Create a transformation for the chamfer
        chamfer_transform = Geom::Transformation.scaling(1.0 - distance)

        # For each edge, create a chamfer
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2

          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position

          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )

          # Create a chamfer by creating a new face
          # This is a simplified approach - in a real implementation,
          # you would need to handle various edge cases
          new_points = []

          # For each vertex of the edge
          [edge.start, edge.end].each do |vertex|
            # Get all edges connected to this vertex
            connected_edges = vertex.edges - [edge]

            # For each connected edge
            connected_edges.each do |connected_edge|
              # Get the other vertex of the connected edge
              other_vertex = (connected_edge.vertices - [vertex])[0]

              # Calculate a point along the connected edge
              direction = other_vertex.position - vertex.position
              new_point = vertex.position.offset(direction, distance)

              new_points << new_point
            end
          end

          # Create a new face using the new points
          if new_points.length >= 3
            result_group.entities.add_face(new_points)
          end
        end

        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end

        # Return the result
        {
          success: true,
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in chamfer_edges: #{e.message}"
        log e.backtrace.join("\n")

        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?

        raise
      end
    end

    def fillet_edges(params)
      log "Filleting edges with params: #{params.inspect}"
      model = Sketchup.active_model

      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"

      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end

      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Fillet operation requires a group or component instance"
      end

      # Get the radius parameter
      radius = params["radius"] || 0.5

      # Get the number of segments for the fillet
      segments = params["segments"] || 8

      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities

      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)

      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end

      # Create a new group to hold the result
      result_group = model.active_entities.add_group

      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end

      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)

      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end

      # Perform the fillet operation
      begin
        # For each edge, create a fillet
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2

          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position

          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )

          # Calculate the edge vector
          edge_vector = end_point - start_point
          edge_length = edge_vector.length

          # Create points for the fillet curve
          fillet_points = []

          # Create a series of points along a circular arc
          (0..segments).each do |i|
            angle = Math::PI * i / segments

            # Calculate the point on the arc
            x = midpoint.x + radius * Math.cos(angle)
            y = midpoint.y + radius * Math.sin(angle)
            z = midpoint.z

            fillet_points << Geom::Point3d.new(x, y, z)
          end

          # Create edges connecting the fillet points
          (0...fillet_points.length - 1).each do |i|
            result_group.entities.add_line(fillet_points[i], fillet_points[i+1])
          end

          # Create a face from the fillet points
          if fillet_points.length >= 3
            result_group.entities.add_face(fillet_points)
          end
        end

        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end

        # Return the result
        {
          success: true,
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in fillet_edges: #{e.message}"
        log e.backtrace.join("\n")

        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?

        raise
      end
    end

    def create_mortise_tenon(params)
      log "Creating mortise and tenon joint with params: #{params.inspect}"
      model = Sketchup.active_model

      # Get the mortise and tenon board IDs
      mortise_id = params["mortise_id"].to_s.gsub('"', '')
      tenon_id = params["tenon_id"].to_s.gsub('"', '')

      log "Looking for mortise board with ID: #{mortise_id}"
      mortise_board = model.find_entity_by_id(mortise_id.to_i)

      log "Looking for tenon board with ID: #{tenon_id}"
      tenon_board = model.find_entity_by_id(tenon_id.to_i)

      unless mortise_board && tenon_board
        missing = []
        missing << "mortise board" unless mortise_board
        missing << "tenon board" unless tenon_board
        raise "Entity not found: #{missing.join(', ')}"
      end

      # Ensure both entities are groups or component instances
      unless (mortise_board.is_a?(Sketchup::Group) || mortise_board.is_a?(Sketchup::ComponentInstance)) &&
             (tenon_board.is_a?(Sketchup::Group) || tenon_board.is_a?(Sketchup::ComponentInstance))
        raise "Mortise and tenon operation requires groups or component instances"
      end

      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 1.0
      depth = params["depth"] || 1.0
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0

      # Get the bounds of both boards
      mortise_bounds = mortise_board.bounds
      tenon_bounds = tenon_board.bounds

      # Determine the face to place the joint on based on the relative positions of the boards
      mortise_center = mortise_bounds.center
      tenon_center = tenon_bounds.center

      # Calculate the direction vector from mortise to tenon
      direction_vector = tenon_center - mortise_center

      # Determine which face of the mortise board is closest to the tenon board
      mortise_face_direction = determine_closest_face(direction_vector)

      # Create the mortise (hole) in the mortise board
      mortise_result = create_mortise(
        mortise_board,
        width,
        height,
        depth,
        mortise_face_direction,
        mortise_bounds,
        offset_x,
        offset_y,
        offset_z
      )

      # Determine which face of the tenon board is closest to the mortise board
      tenon_face_direction = determine_closest_face(direction_vector.reverse)

      # Create the tenon (projection) on the tenon board
      tenon_result = create_tenon(
        tenon_board,
        width,
        height,
        depth,
        tenon_face_direction,
        tenon_bounds,
        offset_x,
        offset_y,
        offset_z
      )

      # Return the result
      {
        success: true,
        mortise_id: mortise_result[:id],
        tenon_id: tenon_result[:id]
      }
    end

    def determine_closest_face(direction_vector)
      # Normalize the direction vector
      direction_vector.normalize!

      # Determine which axis has the largest component
      x_abs = direction_vector.x.abs
      y_abs = direction_vector.y.abs
      z_abs = direction_vector.z.abs

      if x_abs >= y_abs && x_abs >= z_abs
        # X-axis is dominant
        return direction_vector.x > 0 ? :east : :west
      elsif y_abs >= x_abs && y_abs >= z_abs
        # Y-axis is dominant
        return direction_vector.y > 0 ? :north : :south
      else
        # Z-axis is dominant
        return direction_vector.z > 0 ? :top : :bottom
      end
    end

    def create_mortise(board, width, height, depth, face_direction, bounds, offset_x, offset_y, offset_z)
      model = Sketchup.active_model

      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities

      # Calculate the position of the mortise based on the face direction
      mortise_position = calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)

      log "Creating mortise at position: #{mortise_position.inspect} with dimensions: #{[width, height, depth].inspect}"

      # Create a box for the mortise
      mortise_group = entities.add_group

      # Create the mortise box with the correct orientation
      case face_direction
      when :east, :west
        # Mortise on east or west face (YZ plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0], mortise_position[1] + width, mortise_position[2]],
          [mortise_position[0], mortise_position[1] + width, mortise_position[2] + height],
          [mortise_position[0], mortise_position[1], mortise_position[2] + height]
        )
        mortise_face.pushpull(face_direction == :east ? -depth : depth)
      when :north, :south
        # Mortise on north or south face (XZ plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2] + height],
          [mortise_position[0], mortise_position[1], mortise_position[2] + height]
        )
        mortise_face.pushpull(face_direction == :north ? -depth : depth)
      when :top, :bottom
        # Mortise on top or bottom face (XY plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1] + height, mortise_position[2]],
          [mortise_position[0], mortise_position[1] + height, mortise_position[2]]
        )
        mortise_face.pushpull(face_direction == :top ? -depth : depth)
      end

      # Subtract the mortise from the board
      entities.subtract(mortise_group.entities)

      # Clean up the temporary group
      mortise_group.erase!

      # Return the result
      {
        success: true,
        id: board.entityID
      }
    end

    def create_tenon(board, width, height, depth, face_direction, bounds, offset_x, offset_y, offset_z)
      model = Sketchup.active_model

      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities

      # Calculate the position of the tenon based on the face direction
      tenon_position = calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)

      log "Creating tenon at position: #{tenon_position.inspect} with dimensions: #{[width, height, depth].inspect}"

      # Create a box for the tenon
      tenon_group = model.active_entities.add_group

      # Create the tenon box with the correct orientation
      case face_direction
      when :east, :west
        # Tenon on east or west face (YZ plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0], tenon_position[1] + width, tenon_position[2]],
          [tenon_position[0], tenon_position[1] + width, tenon_position[2] + height],
          [tenon_position[0], tenon_position[1], tenon_position[2] + height]
        )
        tenon_face.pushpull(face_direction == :east ? depth : -depth)
      when :north, :south
        # Tenon on north or south face (XZ plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2] + height],
          [tenon_position[0], tenon_position[1], tenon_position[2] + height]
        )
        tenon_face.pushpull(face_direction == :north ? depth : -depth)
      when :top, :bottom
        # Tenon on top or bottom face (XY plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1] + height, tenon_position[2]],
          [tenon_position[0], tenon_position[1] + height, tenon_position[2]]
        )
        tenon_face.pushpull(face_direction == :top ? depth : -depth)
      end

      # Get the transformation of the board
      board_transform = board.transformation

      # Apply the inverse transformation to the tenon group
      tenon_group.transform!(board_transform.inverse)

      # Union the tenon with the board
      board_entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      board_entities.add_instance(tenon_group.entities.parent, Geom::Transformation.new)

      # Clean up the temporary group
      tenon_group.erase!

      # Return the result
      {
        success: true,
        id: board.entityID
      }
    end

    def calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)
      # Calculate the position on the specified face with offsets
      case face_direction
      when :east
        # Position on the east face (max X)
        [
          bounds.max.x,
          bounds.center.y - width/2 + offset_y,
          bounds.center.z - height/2 + offset_z
        ]
      when :west
        # Position on the west face (min X)
        [
          bounds.min.x,
          bounds.center.y - width/2 + offset_y,
          bounds.center.z - height/2 + offset_z
        ]
      when :north
        # Position on the north face (max Y)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.max.y,
          bounds.center.z - height/2 + offset_z
        ]
      when :south
        # Position on the south face (min Y)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.min.y,
          bounds.center.z - height/2 + offset_z
        ]
      when :top
        # Position on the top face (max Z)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.center.y - height/2 + offset_y,
          bounds.max.z
        ]
      when :bottom
        # Position on the bottom face (min Z)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.center.y - height/2 + offset_y,
          bounds.min.z
        ]
      end
    end

    def create_dovetail(params)
      log "Creating dovetail joint with params: #{params.inspect}"
      model = Sketchup.active_model

      # Get the tail and pin board IDs
      tail_id = params["tail_id"].to_s.gsub('"', '')
      pin_id = params["pin_id"].to_s.gsub('"', '')

      log "Looking for tail board with ID: #{tail_id}"
      tail_board = model.find_entity_by_id(tail_id.to_i)

      log "Looking for pin board with ID: #{pin_id}"
      pin_board = model.find_entity_by_id(pin_id.to_i)

      unless tail_board && pin_board
        missing = []
        missing << "tail board" unless tail_board
        missing << "pin board" unless pin_board
        raise "Entity not found: #{missing.join(', ')}"
      end

      # Ensure both entities are groups or component instances
      unless (tail_board.is_a?(Sketchup::Group) || tail_board.is_a?(Sketchup::ComponentInstance)) &&
             (pin_board.is_a?(Sketchup::Group) || pin_board.is_a?(Sketchup::ComponentInstance))
        raise "Dovetail operation requires groups or component instances"
      end

      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 2.0
      depth = params["depth"] || 1.0
      angle = params["angle"] || 15.0  # Dovetail angle in degrees
      num_tails = params["num_tails"] || 3
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0

      # Create the tails on the tail board
      tail_result = create_tails(tail_board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)

      # Create the pins on the pin board
      pin_result = create_pins(pin_board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)

      # Return the result
      {
        success: true,
        tail_id: tail_result[:id],
        pin_id: pin_result[:id]
      }
    end

    def create_tails(board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      model = Sketchup.active_model

      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities

      # Get the board's bounds
      bounds = board.bounds

      # Calculate the position of the dovetail joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z

      # Calculate the width of each tail and space
      total_width = width
      tail_width = total_width / (2 * num_tails - 1)

      # Create a group for the tails
      tails_group = entities.add_group

      # Create each tail
      num_tails.times do |i|
        # Calculate the position of this tail
        tail_center_x = center_x - width/2 + tail_width * (2 * i)

        # Calculate the dovetail shape
        angle_rad = angle * Math::PI / 180.0
        tail_top_width = tail_width
        tail_bottom_width = tail_width + 2 * depth * Math.tan(angle_rad)

        # Create the tail shape
        tail_points = [
          [tail_center_x - tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_bottom_width/2, center_y - height/2, center_z - depth],
          [tail_center_x - tail_bottom_width/2, center_y - height/2, center_z - depth]
        ]

        # Create the tail face
        tail_face = tails_group.entities.add_face(tail_points)

        # Extrude the tail
        tail_face.pushpull(height)
      end

      # Return the result
      {
        success: true,
        id: board.entityID
      }
    end

    def create_pins(board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      model = Sketchup.active_model

      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities

      # Get the board's bounds
      bounds = board.bounds

      # Calculate the position of the dovetail joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z

      # Calculate the width of each tail and space
      total_width = width
      tail_width = total_width / (2 * num_tails - 1)

      # Create a group for the pins
      pins_group = entities.add_group

      # Create a box for the entire pin area
      pin_area_face = pins_group.entities.add_face(
        [center_x - width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y + height/2, center_z],
        [center_x - width/2, center_y + height/2, center_z]
      )

      # Extrude the pin area
      pin_area_face.pushpull(depth)

      # Create each tail cutout
      num_tails.times do |i|
        # Calculate the position of this tail
        tail_center_x = center_x - width/2 + tail_width * (2 * i)

        # Calculate the dovetail shape
        angle_rad = angle * Math::PI / 180.0
        tail_top_width = tail_width
        tail_bottom_width = tail_width + 2 * depth * Math.tan(angle_rad)

        # Create a group for the tail cutout
        tail_cutout_group = entities.add_group

        # Create the tail cutout shape
        tail_points = [
          [tail_center_x - tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_bottom_width/2, center_y - height/2, center_z - depth],
          [tail_center_x - tail_bottom_width/2, center_y - height/2, center_z - depth]
        ]

        # Create the tail cutout face
        tail_face = tail_cutout_group.entities.add_face(tail_points)

        # Extrude the tail cutout
        tail_face.pushpull(height)

        # Subtract the tail cutout from the pin area
        pins_group.entities.subtract(tail_cutout_group.entities)

        # Clean up the temporary group
        tail_cutout_group.erase!
      end

      # Return the result
      {
        success: true,
        id: board.entityID
      }
    end

    def create_finger_joint(params)
      log "Creating finger joint with params: #{params.inspect}"
      model = Sketchup.active_model

      # Get the two board IDs
      board1_id = params["board1_id"].to_s.gsub('"', '')
      board2_id = params["board2_id"].to_s.gsub('"', '')

      log "Looking for board 1 with ID: #{board1_id}"
      board1 = model.find_entity_by_id(board1_id.to_i)

      log "Looking for board 2 with ID: #{board2_id}"
      board2 = model.find_entity_by_id(board2_id.to_i)

      unless board1 && board2
        missing = []
        missing << "board 1" unless board1
        missing << "board 2" unless board2
        raise "Entity not found: #{missing.join(', ')}"
      end

      # Ensure both entities are groups or component instances
      unless (board1.is_a?(Sketchup::Group) || board1.is_a?(Sketchup::ComponentInstance)) &&
             (board2.is_a?(Sketchup::Group) || board2.is_a?(Sketchup::ComponentInstance))
        raise "Finger joint operation requires groups or component instances"
      end

      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 2.0
      depth = params["depth"] || 1.0
      num_fingers = params["num_fingers"] || 5
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0

      # Create the fingers on board 1
      board1_result = create_board1_fingers(board1, width, height, depth, num_fingers, offset_x, offset_y, offset_z)

      # Create the matching slots on board 2
      board2_result = create_board2_slots(board2, width, height, depth, num_fingers, offset_x, offset_y, offset_z)

      # Return the result
      {
        success: true,
        board1_id: board1_result[:id],
        board2_id: board2_result[:id]
      }
    end

    def create_board1_fingers(board, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      model = Sketchup.active_model

      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities

      # Get the board's bounds
      bounds = board.bounds

      # Calculate the position of the joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z

      # Calculate the width of each finger
      finger_width = width / num_fingers

      # Create a group for the fingers
      fingers_group = entities.add_group

      # Create a base rectangle for the joint area
      base_face = fingers_group.entities.add_face(
        [center_x - width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y + height/2, center_z],
        [center_x - width/2, center_y + height/2, center_z]
      )

      # Create cutouts for the spaces between fingers
      (num_fingers / 2).times do |i|
        # Calculate the position of this cutout
        cutout_center_x = center_x - width/2 + finger_width * (2 * i + 1)

        # Create a group for the cutout
        cutout_group = entities.add_group

        # Create the cutout shape
        cutout_face = cutout_group.entities.add_face(
          [cutout_center_x - finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y + height/2, center_z],
          [cutout_center_x - finger_width/2, center_y + height/2, center_z]
        )

        # Extrude the cutout
        cutout_face.pushpull(depth)

        # Subtract the cutout from the fingers
        fingers_group.entities.subtract(cutout_group.entities)

        # Clean up the temporary group
        cutout_group.erase!
      end

      # Extrude the fingers
      base_face.pushpull(depth)

      # Return the result
      {
        success: true,
        id: board.entityID
      }
    end

    def create_board2_slots(board, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      model = Sketchup.active_model

      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities

      # Get the board's bounds
      bounds = board.bounds

      # Calculate the position of the joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z

      # Calculate the width of each finger
      finger_width = width / num_fingers

      # Create a group for the slots
      slots_group = entities.add_group

      # Create cutouts for the fingers from board 1
      (num_fingers / 2 + num_fingers % 2).times do |i|
        # Calculate the position of this cutout
        cutout_center_x = center_x - width/2 + finger_width * (2 * i)

        # Create a group for the cutout
        cutout_group = entities.add_group

        # Create the cutout shape
        cutout_face = cutout_group.entities.add_face(
          [cutout_center_x - finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y + height/2, center_z],
          [cutout_center_x - finger_width/2, center_y + height/2, center_z]
        )

        # Extrude the cutout
        cutout_face.pushpull(depth)

        # Subtract the cutout from the board
        entities.subtract(cutout_group.entities)

        # Clean up the temporary group
        cutout_group.erase!
      end

      # Return the result
      {
        success: true,
        id: board.entityID
      }
    end

    def eval_ruby(params)
      log "Evaluating Ruby code with length: #{params['code'].length}"

      begin
        # Create a safe binding for evaluation
        binding = TOPLEVEL_BINDING.dup

        # Evaluate the Ruby code
        log "Starting code evaluation..."
        result = eval(params["code"], binding)
        log "Code evaluation completed with result: #{result.inspect}"

        # Return success with the result as a string
        {
          success: true,
          result: result.to_s
        }
      rescue StandardError => e
        log "Error in eval_ruby: #{e.message}"
        log e.backtrace.join("\n")
        raise "Ruby evaluation error: #{e.message}"
      end
    end
  end

  unless file_loaded?(__FILE__)
    @server = Server.new

    menu = UI.menu("Plugins").add_submenu("MCP Server")
    menu.add_item("Start Server") { @server.start }
    menu.add_item("Stop Server") { @server.stop }

    file_loaded(__FILE__)
  end
end