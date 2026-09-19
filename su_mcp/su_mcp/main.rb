require 'sketchup'
require 'json'
require 'socket'
require 'fileutils'
require 'tmpdir'

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
          client = nil
          begin
            if @running
              # Check for connection
              ready = IO.select([@server], nil, nil, 0)
              if ready
                log "Connection waiting..."
                client = @server.accept_nonblock
                log "Client accepted"

                # Never block the main thread waiting for input: a client that
                # connects and stays idle (e.g. a warm-up/health-check socket)
                # is dropped after a short deadline instead of freezing SketchUp.
                data = read_request(client)
                log "Raw data: #{data.inspect}"

                if data
                  respond_to_request(client, data)
                end

                log "Client closed"
              end
            end
          rescue IO::WaitReadable
            # Normal for accept_nonblock
          rescue Exception => e
            # Rescue Exception, not just StandardError: bridge requests may
            # raise SyntaxError/SystemStackError/etc., and letting those escape
            # used to leave the client without any response until it timed out.
            log "Timer error: #{e.class}: #{e.message}"
            log e.backtrace.join("\n") if e.backtrace
            begin
              client.write({
                jsonrpc: "2.0",
                error: { code: -32603, message: "#{e.class}: #{e.message}" },
                id: nil
              }.to_json + "\n")
              client.flush
            rescue Exception
              # Client is gone; nothing else we can do.
            end
          ensure
            client.close if client && !client.closed?
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

    # Read one newline-terminated request without ever blocking indefinitely.
    # Returns nil when the client sends nothing before the deadline.
    def read_request(client, deadline_seconds = 2)
      buffer = "".dup
      deadline = Time.now + deadline_seconds
      while (remaining = deadline - Time.now) > 0
        ready = IO.select([client], nil, nil, remaining)
        break unless ready
        begin
          chunk = client.read_nonblock(65_536)
          buffer << chunk
          break if buffer.include?("\n")
        rescue IO::WaitReadable
          retry
        rescue EOFError, Errno::ECONNRESET
          break
        end
      end
      buffer.include?("\n") ? buffer : nil
    end

    # Parse the request and always write exactly one response, even when
    # handling raises an unexpected exception class.
    def respond_to_request(client, data)
      original_id = nil
      if data =~ /"id":\s*(\d+)/
        original_id = $1.to_i
        log "Found original request ID: #{original_id}"
      end

      begin
        request = JSON.parse(data)
        request["id"] = original_id if !request["id"] && original_id
        response = handle_jsonrpc_request(request)
      rescue JSON::ParserError => e
        log "JSON parse error: #{e.message}"
        response = {
          jsonrpc: "2.0",
          error: { code: -32700, message: "Parse error: #{e.message}" },
          id: original_id
        }
      rescue Exception => e
        log "Request error: #{e.class}: #{e.message}"
        response = {
          jsonrpc: "2.0",
          error: { code: -32603, message: "#{e.class}: #{e.message}" },
          id: original_id
        }
      end

      response_json = response.to_json + "\n"
      client.write(response_json)
      client.flush
      log "Response sent"
    end

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
        when "get_model_info"
          get_model_info(args)
        when "set_camera"
          set_camera(args)
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
          # Surface tool-specific fields (export path/format, joint ids,
          # selection entities, ...) instead of dropping them.
          extras = result.reject { |k, _| [:success, :result, :id].include?(k) }
          text = result[:result]
          if text.nil?
            text = extras.empty? ? "Success" : extras.map { |k, v| "#{k}: #{v}" }.join("; ")
          end
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            result: {
              content: [{ type: "text", text: text }],
              isError: false,
              success: true,
              resourceId: result[:id]
            }.merge(extras),
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

    # SketchUp's internal length unit is the inch; convert user-supplied
    # values so tools can work in mm/cm/m without mental math.
    UNIT_TO_INCH = {
      "inch" => 1.0,
      "in"   => 1.0,
      "mm"   => 1.0 / 25.4,
      "cm"   => 1.0 / 2.54,
      "m"    => 100.0 / 2.54
    }.freeze

    def create_component(params)
      log "Creating component with params: #{params.inspect}"
      model = Sketchup.active_model
      entities = model.active_entities

      pos = params["position"] || [0,0,0]
      dims = params["dimensions"] || [1,1,1]
      unit = (params["unit"] || "inch").to_s.downcase
      factor = UNIT_TO_INCH[unit]
      raise "Unknown unit: #{unit.inspect} (supported: inch, mm, cm, m)" unless factor
      pos = pos.map { |v| v.to_f * factor }
      dims = dims.map { |v| v.to_f * factor }

      # Build the geometry at the origin of a component definition, then place
      # one instance at the requested position, so callers get a real reusable
      # component instead of loose grouped geometry.
      base_name = "MCP #{params["type"].to_s.capitalize}"
      definition_name = base_name
      n = 2
      while model.definitions[definition_name]
        definition_name = "#{base_name} #{n}"
        n += 1
      end
      definition = model.definitions.add(definition_name)

      case params["type"]
      when "cube"
        face = definition.entities.add_face(
          [0, 0, 0],
          [dims[0], 0, 0],
          [dims[0], dims[1], 0],
          [0, dims[1], 0]
        )
        face.reverse! if face.normal.z < 0
        face.pushpull(dims[2])
      when "cylinder"
        radius = dims[0] / 2.0
        height = dims[2]
        num_segments = 24
        circle_points = (0...num_segments).map do |i|
          angle = Math::PI * 2 * i / num_segments
          [radius + radius * Math.cos(angle), radius + radius * Math.sin(angle), 0]
        end
        face = definition.entities.add_face(circle_points)
        face.reverse! if face.normal.z < 0
        face.pushpull(height)
      when "sphere"
        radius = dims[0] / 2.0
        center = [radius, radius, radius]
        segments = 16
        rings = segments / 2
        ring_pts = []
        (1...rings).each do |r|
          lat = Math::PI * r / rings
          ring_pts << (0...segments).map { |s|
            lon = 2 * Math::PI * s / segments
            [center[0] + radius * Math.sin(lat) * Math.cos(lon),
             center[1] + radius * Math.sin(lat) * Math.sin(lon),
             center[2] + radius * Math.cos(lat)]
          }
        end
        north = Geom::Point3d.new(center[0], center[1], center[2] + radius)
        south = Geom::Point3d.new(center[0], center[1], center[2] - radius)
        (0...segments).each do |s|
          definition.entities.add_face(north, ring_pts[0][s], ring_pts[0][(s + 1) % segments])
        end
        (0...(ring_pts.size - 1)).each do |r|
          (0...segments).each do |s|
            s2 = (s + 1) % segments
            definition.entities.add_face(ring_pts[r][s], ring_pts[r][s2], ring_pts[r + 1][s2], ring_pts[r + 1][s])
          end
        end
        last = ring_pts[-1]
        (0...segments).each do |s|
          definition.entities.add_face(south, last[(s + 1) % segments], last[s])
        end
      when "cone"
        radius = dims[0] / 2.0
        height = dims[2]
        num_segments = 24
        circle_points = (0...num_segments).map do |i|
          angle = Math::PI * 2 * i / num_segments
          [radius + radius * Math.cos(angle), radius + radius * Math.sin(angle), 0]
        end
        apex = Geom::Point3d.new(radius, radius, height)
        definition.entities.add_face(circle_points)
        (0...num_segments).each do |i|
          j = (i + 1) % num_segments
          definition.entities.add_face(circle_points[i], circle_points[j], apex)
        end
      else
        raise "Unknown component type: #{params["type"]}"
      end

      instance = entities.add_instance(
        definition,
        Geom::Transformation.translation(Geom::Vector3d.new(pos[0], pos[1], pos[2]))
      )
      log "Created #{definition_name} instance ##{instance.entityID}"

      {
        success: true,
        id: instance.entityID,
        definition: definition_name,
        unit: unit
      }
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

    LENGTH_UNIT_NAMES = {
      1 => "inches", 2 => "feet", 3 => "millimeters",
      4 => "centimeters", 5 => "meters"
    }.freeze

    # Read-only model inspection. Without an id: global summary (entity counts,
    # bounds, scenes, layers, materials, units, selection). With an id:
    # details for one entity (bounds, layer, volume, surface area, ...).
    # Lengths go through Sketchup.format_length so they respect model units.
    def get_model_info(params)
      model = Sketchup.active_model
      raise "No active model" unless model

      if params && params["id"]
        id = params["id"].to_s.gsub('"', '').to_i
        entity = model.find_entity_by_id(id)
        raise "Entity not found: #{params['id']}" unless entity

        info = { id: entity.entityID, type: entity.typename }
        info[:name] = entity.name if entity.respond_to?(:name) && !entity.name.to_s.empty?
        info[:layer] = entity.layer.name if entity.respond_to?(:layer)
        info[:hidden] = entity.hidden? if entity.respond_to?(:hidden?)
        info[:locked] = entity.locked? if entity.respond_to?(:locked?)
        info[:material] = entity.material.name if entity.respond_to?(:material) && entity.material

        if entity.respond_to?(:bounds) && !entity.bounds.empty?
          bb = entity.bounds
          info[:bounds_min] = bb.min.to_a.map { |v| Sketchup.format_length(v) }
          info[:bounds_max] = bb.max.to_a.map { |v| Sketchup.format_length(v) }
          info[:bounds_size] = [bb.width, bb.depth, bb.height].map { |v| Sketchup.format_length(v) }
        end

        if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          ents = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
          info[:definition] = entity.definition.name if entity.is_a?(Sketchup::ComponentInstance)
          faces = ents.grep(Sketchup::Face)
          info[:faces] = faces.size
          info[:edges] = ents.grep(Sketchup::Edge).size
          info[:surface_area] = Sketchup.format_area(faces.sum(&:area))
          begin
            info[:volume] = Sketchup.format_volume(entity.volume) if entity.volume > 0
          rescue
            # volume raises on non-solids; just omit it
          end
        elsif entity.is_a?(Sketchup::Face)
          info[:area] = Sketchup.format_area(entity.area)
        end

        return { success: true, result: JSON.pretty_generate(info) }
      end

      counts = Hash.new(0)
      model.entities.each { |e| counts[e.typename] += 1 }

      info = {
        title: model.title,
        path: model.path,
        modified: model.modified?,
        total_entities: model.entities.count,
        entities_by_type: counts,
        faces: model.number_faces
      }

      unless model.bounds.empty?
        bb = model.bounds
        info[:model_bounds_min] = bb.min.to_a.map { |v| Sketchup.format_length(v) }
        info[:model_bounds_max] = bb.max.to_a.map { |v| Sketchup.format_length(v) }
        info[:model_size] = [bb.width, bb.depth, bb.height].map { |v| Sketchup.format_length(v) }
      end

      info[:scenes] = model.pages.map(&:name)
      info[:active_scene] = model.pages.selected_page ? model.pages.selected_page.name : nil
      info[:layers] = model.layers.map(&:name)
      info[:active_layer] = model.active_layer.name
      info[:materials] = model.materials.map(&:name)
      units = model.options["UnitsOptions"]
      info[:units] = {
        length: LENGTH_UNIT_NAMES[units["LengthUnit"]] || units["LengthUnit"],
        precision: units["LengthPrecision"],
        format: units["LengthFormat"]
      }
      selection = model.selection
      info[:selection_count] = selection.size
      info[:selection] = selection.to_a.first(20).map do |e|
        entry = { id: e.entityID, type: e.typename }
        entry[:name] = e.name if e.respond_to?(:name) && !e.name.to_s.empty?
        entry
      end

      { success: true, result: JSON.pretty_generate(info) }
    end

    # Position the camera by standard view name, or explicit eye/target/up.
    # All points are in SketchUp internal inches.
    def set_camera(params)
      model = Sketchup.active_model
      view = model.active_view
      bb = model.bounds
      center = bb.empty? ? ORIGIN : bb.center
      perspective = params.fetch("perspective", true)

      if params["eye"] && params["target"]
        view_name = "custom"
        eye = Geom::Point3d.new(params["eye"].map(&:to_f))
        target = Geom::Point3d.new(params["target"].map(&:to_f))
        up = params["up"] ? Geom::Vector3d.new(params["up"].map(&:to_f)) : Z_AXIS
      elsif params["standard_view"]
        view_name = params["standard_view"].to_s.downcase
        directions = {
          "top"    => [[0, 0, 1],  [0, 1, 0]],
          "bottom" => [[0, 0, -1], [0, 1, 0]],
          "front"  => [[0, -1, 0], [0, 0, 1]],
          "back"   => [[0, 1, 0],  [0, 0, 1]],
          "right"  => [[1, 0, 0],  [0, 0, 1]],
          "left"   => [[-1, 0, 0], [0, 0, 1]],
          "iso"    => [[1, -1, 1], [0, 0, 1]]
        }
        dir_up = directions[view_name]
        raise "Unknown standard_view '#{view_name}' (use top/bottom/front/back/left/right/iso)" unless dir_up
        dir = Geom::Vector3d.new(dir_up[0]).normalize
        dist = bb.empty? ? 100.0 : bb.diagonal * 1.2
        eye = center.offset(dir, dist)
        target = center
        up = Geom::Vector3d.new(dir_up[1])
      else
        raise "Provide either standard_view or eye + target"
      end

      camera = Sketchup::Camera.new(eye, target, up, perspective)
      camera.fov = params["fov"].to_f if params["fov"]
      view.camera = camera
      view.zoom_extents if params["zoom_extents"]

      {
        success: true,
        view: view_name,
        eye: eye.to_a.map { |v| v.round(4) },
        target: target.to_a.map { |v| v.round(4) },
        perspective: perspective
      }
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
    
    # Copy an entity's geometry into a fresh solid Group at the same world
    # position. Group#entities.parent exposes the group's hidden definition,
    # so the same add_instance path works for groups and component instances.
    # The nested instance is exploded so the wrapper is a manifold solid,
    # which the native boolean methods require.
    def to_solid_group(entity)
      model = Sketchup.active_model
      wrapper = model.active_entities.add_group
      definition = entity.is_a?(Sketchup::Group) ? entity.entities.parent : entity.definition
      instance = wrapper.entities.add_instance(definition, entity.transformation)
      instance.explode
      wrapper
    end

    def boolean_operation(params)
      log "Performing boolean operation with params: #{params.inspect}"
      model = Sketchup.active_model

      operation_type = params["operation"]
      unless ["union", "difference", "intersection"].include?(operation_type)
        raise "Invalid boolean operation: #{operation_type}. Must be 'union', 'difference', or 'intersection'."
      end

      target_entity = model.find_entity_by_id(params["target_id"].to_s.gsub('"', '').to_i)
      tool_entity = model.find_entity_by_id(params["tool_id"].to_s.gsub('"', '').to_i)
      unless target_entity && tool_entity
        raise "Entity not found: #{target_entity ? 'tool' : 'target'}"
      end

      unless (target_entity.is_a?(Sketchup::Group) || target_entity.is_a?(Sketchup::ComponentInstance)) &&
             (tool_entity.is_a?(Sketchup::Group) || tool_entity.is_a?(Sketchup::ComponentInstance))
        raise "Boolean operations require groups or component instances"
      end

      model.start_operation("MCP boolean #{operation_type}", true)
      begin
        target_group = to_solid_group(target_entity)
        tool_group = to_solid_group(tool_entity)

        if target_group.volume <= 0
          raise "Target entity is not a solid (volume is zero)"
        end
        if tool_group.volume <= 0
          raise "Tool entity is not a solid (volume is zero)"
        end

        # Native solid operations consume both operand groups and return a
        # new group with the result.
        result_group = case operation_type
        when "union"
          target_group.union(tool_group)
        when "difference"
          target_group.subtract(tool_group)
        when "intersection"
          target_group.intersect(tool_group)
        end
        raise "#{operation_type} failed" unless result_group

        if params["delete_originals"]
          target_entity.erase! if target_entity.valid?
          tool_entity.erase! if tool_entity.valid?
        end

        model.commit_operation
        { success: true, id: result_group.entityID }
      rescue Exception
        model.abort_operation
        raise
      end
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

      model = Sketchup.active_model
      # Wrap mutations in an undoable operation so a failing script doesn't
      # leave the model half-modified.
      op_open = false
      if model
        model.start_operation("MCP eval_ruby", true)
        op_open = true
      end

      begin
        result = eval(params["code"], TOPLEVEL_BINDING.dup)
        log "Code evaluation completed with result: #{result.inspect}"
        model.commit_operation if op_open
        {
          success: true,
          result: result.to_s
        }
      rescue Exception => e
        # Rescue Exception, not just StandardError: SyntaxError (a ScriptError)
        # and friends escape a plain StandardError rescue and used to kill the
        # request without any response ever being sent back to the client.
        model.abort_operation if op_open
        log "Error in eval_ruby: #{e.class}: #{e.message}"
        log e.backtrace.join("\n") if e.backtrace
        raise "Ruby evaluation error: #{e.class}: #{e.message}"
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