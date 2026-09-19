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
      @start_time = Time.now
      
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
        when "get_viewport_screenshot"
          get_viewport_screenshot(args)
        when "get_addon_status"
          get_addon_status(args)
        when "export", "export_scene"
          export_scene(args)
        when "set_material"
          set_material(args)
        when "boolean_operation"
          boolean_operation(args)
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
    
    # Lightweight health check for the bridge: versions and model state
    # without touching geometry.
    def get_addon_status(params)
      model = Sketchup.active_model
      status = {
        sketchup_version: Sketchup.version.to_s,
        platform: Sketchup.platform.to_s,
        pro: Sketchup.is_pro?,
        model_title: model.title,
        model_path: model.path,
        entities: model.entities.count,
        server_port: @port,
        ruby_version: RUBY_VERSION,
        uptime_seconds: @start_time ? (Time.now - @start_time).round : nil
      }
      { success: true, result: JSON.generate(status) }
    end

    # Write a PNG of the current viewport to a caller-provided path. The
    # Python side passes a temp file, reads the bytes back and returns them
    # as an MCP image block, so the agent sees the viewport directly.
    def get_viewport_screenshot(params)
      model = Sketchup.active_model
      filepath = params["filepath"].to_s
      raise "filepath required" if filepath.empty?

      view = model.active_view
      ok = view.write_image(
        filename: filepath,
        width: (params["width"] || 1600).to_i,
        height: (params["height"] || 900).to_i,
        antialias: true
      )
      raise "write_image failed" unless ok
      { success: true, path: filepath }
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

        # Caller-provided destination wins over the temp dir.
        custom_path = params["filepath"].to_s
        unless custom_path.empty?
          dir = File.dirname(custom_path)
          FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
        end
        
        case format.downcase
        when "skp"
          # Export as SketchUp file
          export_path = custom_path.empty? ? File.join(temp_dir, "#{filename}.skp") : custom_path
          log "Exporting to SketchUp file: #{export_path}"
          begin
            # save_copy keeps the working model's own path binding intact;
            # it requires the model to have been saved once, so unsaved
            # models fall back to save (which binds the export path).
            model.save_copy(export_path)
          rescue ArgumentError
            model.save(export_path)
          end
          
        when "obj"
          # Export as OBJ file
          export_path = custom_path.empty? ? File.join(temp_dir, "#{filename}.obj") : custom_path
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
          export_path = custom_path.empty? ? File.join(temp_dir, "#{filename}.dae") : custom_path
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
          export_path = custom_path.empty? ? File.join(temp_dir, "#{filename}.stl") : custom_path
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
          export_path = custom_path.empty? ? File.join(temp_dir, "#{filename}.#{ext}") : custom_path
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

    # --- Joint helpers -----------------------------------------------------
    # Joints are built by positioning box/trapezoid prisms in world space and
    # applying the native solid operations: mortises and slots subtract,
    # tenons and fingers union. All dimensions are in inches after
    # convert_joint_units! has scaled the caller's unit.

    # Per face direction: [normal axis, normal sign, width axis, height axis].
    FACE_FRAMES = {
      east:  [0,  1, 1, 2], west:  [0, -1, 1, 2],
      north: [1,  1, 0, 2], south: [1, -1, 0, 2],
      top:   [2,  1, 0, 1], bottom: [2, -1, 0, 1]
    }.freeze

    def convert_joint_units!(params)
      unit = (params["unit"] || "inch").to_s.downcase
      factor = UNIT_TO_INCH[unit]
      raise "Unknown unit: #{unit.inspect} (supported: inch, mm, cm, m)" unless factor
      ["width", "height", "depth", "offset_x", "offset_y", "offset_z"].each do |k|
        params[k] = params[k].to_f * factor if params[k]
      end
    end

    def find_board(id_value, label)
      model = Sketchup.active_model
      board = model.find_entity_by_id(id_value.to_s.gsub('"', '').to_i)
      raise "#{label} not found (id #{id_value})" unless board
      unless board.is_a?(Sketchup::Group) || board.is_a?(Sketchup::ComponentInstance)
        raise "#{label} must be a group or component instance"
      end
      board
    end

    def joint_offsets(params)
      [params["offset_x"].to_f, params["offset_y"].to_f, params["offset_z"].to_f]
    end

    # Joints are cut with classic SketchUp geometry (face split + pushpull)
    # instead of the native solid operations: the solid ops proved
    # unreliable for small joinery features, sometimes returning the
    # intersection instead of the difference. This way boards keep their
    # entity IDs, and it requires no Pro solid tools.

    # Geometry container and world->local transform of a board. Component
    # instances are edited through their definition; assume the definition
    # is not shared between unrelated instances.
    def board_context(board)
      if board.is_a?(Sketchup::Group)
        [board.entities, board.transformation.inverse]
      else
        [board.definition.entities, board.transformation.inverse]
      end
    end

    # Four corners of a rectangle on the face plane of the bounds, world
    # coordinates. ta0/tb0 are the lower corner on the width/height axes.
    def face_rect_world(bounds, dir, ta0, len_ta, tb0, len_tb)
      axis, sign, ta, tb = FACE_FRAMES[dir]
      plane = sign > 0 ? bounds.max.to_a[axis] : bounds.min.to_a[axis]
      [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]].map do |i, j|
        p = [0.0, 0.0, 0.0]
        p[axis] = plane
        p[ta] = ta0 + i * len_ta
        p[tb] = tb0 + j * len_tb
        p
      end
    end

    # Centered rectangle start on both tangential axes (width along the
    # width axis, height along the height axis), shifted by world offsets.
    def centered_face_rect(bounds, dir, width, height, offsets)
      axis, sign, ta, tb = FACE_FRAMES[dir]
      center = bounds.center.to_a
      ta0 = center[ta] - width / 2.0 + offsets[ta]
      tb0 = center[tb] - height / 2.0 + offsets[tb]
      face_rect_world(bounds, dir, ta0, width, tb0, height)
    end

    # Draw rect_corners (world) on the board's face in the given direction
    # and pushpull it by distance: inward cuts a slot, outward grows a
    # tenon/finger. The board is modified in place; raises when the volume
    # change does not match (face not on the board surface, non-box board).
    def cut_or_grow(board, dir, rect_corners, distance, inward, expected_delta)
      model = Sketchup.active_model
      entities, inv = board_context(board)
      local_pts = rect_corners.map { |p| Geom::Point3d.new(*p).transform(inv) }
      before_bb = board.bounds
      before_faces = entities.grep(Sketchup::Face).size

      before = board.volume
      face = entities.add_face(local_pts)
      raise "Could not create a face on the board surface; is the board face aligned with its bounds?" unless face

      # add_face on an existing surface splits it and may return either of
      # the two resulting regions. If we got the surrounding region instead
      # of the feature rectangle, find the small face at the rect center.
      rect_area = local_pts[0].distance(local_pts[1]) * local_pts[1].distance(local_pts[2])
      if (face.area - rect_area).abs > rect_area * 0.01
        center_local = Geom::Point3d.new(
          local_pts.map { |p| p.x }.sum / 4.0,
          local_pts.map { |p| p.y }.sum / 4.0,
          local_pts.map { |p| p.z }.sum / 4.0
        )
        small = entities.grep(Sketchup::Face).select do |f|
          (f.area - rect_area).abs <= rect_area * 0.01
        end
        face = small.min_by { |f| (f.bounds.center - center_local).length }
        raise "Feature rectangle not found on the board face" unless face
      end

      axis, sign, = FACE_FRAMES[dir]
      n_world = Geom::Vector3d.new(0, 0, 0)
      n_world[axis] = sign
      n_local = n_world.transform(inv)
      face.reverse! if face.normal % n_local < 0
      face.pushpull(inward ? -distance : distance)

      after = board.volume
      if after >= 0
        actual = (after - before).abs
        if (actual - expected_delta).abs > expected_delta * 0.01 + 1e-6
          raise "Joint cut did not land on the board face (volume changed by #{actual.round(4)} instead of #{expected_delta.round(4)}); the board may not be axis-aligned or the feature overhangs the face"
        end
      else
        # SketchUp reports a negative sentinel volume for solids it cannot
        # evaluate right after an edit; fall back to geometric checks.
        after_bb = board.bounds
        after_faces = entities.grep(Sketchup::Face).size
        axis, sign, = FACE_FRAMES[dir]
        ok = after_faces > before_faces
        if inward
          grew = (after_bb.max.to_a[axis] - before_bb.max.to_a[axis]).abs < 1e-4 &&
                 (after_bb.min.to_a[axis] - before_bb.min.to_a[axis]).abs < 1e-4
        else
          face_coord = sign > 0 ? after_bb.max.to_a[axis] - before_bb.max.to_a[axis]
                                : before_bb.min.to_a[axis] - after_bb.min.to_a[axis]
          grew = face_coord >= distance * 0.99
        end
        raise "Joint cut did not land on the board face (geometric check failed); the board may not be axis-aligned or the feature overhangs the face" unless ok && grew
      end
      face
    end

    # After a pushpull, find the cap face of the slot/tail (parallel to the
    # opening, at exactly `depth` from the opening plane) and slide it
    # sideways along the width axis, turning the straight feature into a
    # tapered dovetail. Moves the face's edges so neighbouring faces stretch.
    def stretch_end_face(board, dir, rect_corners, depth, taper)
      entities, inv = board_context(board)
      axis, sign, ta, tb = FACE_FRAMES[dir]
      n_world = Geom::Vector3d.new(0, 0, 0)
      n_world[axis] = sign

      cx = rect_corners.map { |c| c[0] }.sum / 4.0
      cy = rect_corners.map { |c| c[1] }.sum / 4.0
      cz = rect_corners.map { |c| c[2] }.sum / 4.0
      opening_local = Geom::Point3d.new(cx, cy, cz).transform(inv)
      # Distance from the opening plane along the normal axis, in local units.
      candidates = entities.grep(Sketchup::Face).select do |f|
        (f.normal % n_world).abs > 0.999
      end
      end_face = candidates.min_by do |f|
        c = f.bounds.center
        ((c - opening_local).length - depth).abs
      end
      raise "Could not find the slot end face to taper" unless end_face

      move = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, 0).tap { |v| v[ta] = taper })
      entities.transform_entities(move, end_face.edges.uniq)
    end

    # --- Joints ------------------------------------------------------------

    def create_mortise_tenon(params)
      log "Creating mortise and tenon joint with params: #{params.inspect}"
      convert_joint_units!(params)
      mortise_board = find_board(params["mortise_id"], "Mortise board")
      tenon_board = find_board(params["tenon_id"], "Tenon board")

      width = params["width"] || 1.0
      height = params["height"] || 1.0
      depth = params["depth"] || 1.0
      offsets = joint_offsets(params)

      model = Sketchup.active_model
      model.start_operation("MCP mortise and tenon", true)
      begin
        direction = mortise_board.bounds.center.vector_to(tenon_board.bounds.center)
        mortise_dir = determine_closest_face(direction)
        tenon_dir = determine_closest_face(direction.reverse)

        rect = centered_face_rect(mortise_board.bounds, mortise_dir, width, height, offsets)
        cut_or_grow(mortise_board, mortise_dir, rect, depth, true, width * height * depth)

        rect = centered_face_rect(tenon_board.bounds, tenon_dir, width, height, offsets)
        cut_or_grow(tenon_board, tenon_dir, rect, depth, false, width * height * depth)

        model.commit_operation
        { success: true, mortise_id: mortise_board.entityID, tenon_id: tenon_board.entityID }
      rescue Exception
        model.abort_operation
        raise
      end
    end

    def create_finger_joint(params)
      log "Creating finger joint with params: #{params.inspect}"
      convert_joint_units!(params)
      board1 = find_board(params["board1_id"], "Board 1")
      board2 = find_board(params["board2_id"], "Board 2")

      width = params["width"] || 1.0
      height = params["height"] || 1.0
      depth = params["depth"] || 1.0
      num_fingers = [(params["num_fingers"] || 5).to_i, 1].max
      offsets = joint_offsets(params)

      model = Sketchup.active_model
      model.start_operation("MCP finger joint", true)
      begin
        direction = board1.bounds.center.vector_to(board2.bounds.center)
        dir1 = determine_closest_face(direction)
        dir2 = determine_closest_face(direction.reverse)
        finger_width = width / num_fingers

        # board1 grows fingers on the near face; board2 gets matching slots
        # on its near face at the same world positions, so the boards
        # interlock when pushed together.
        axis1, sign1, ta1, tb1 = FACE_FRAMES[dir1]
        axis2, sign2, ta2, tb2 = FACE_FRAMES[dir2]
        center1 = board1.bounds.center.to_a
        center2 = board2.bounds.center.to_a
        start1 = center1[ta1] - width / 2.0
        start2 = center2[ta2] - width / 2.0

        (0...num_fingers).each do |i|
          rect = face_rect_world(board1.bounds, dir1,
            start1 + finger_width * i + offsets[ta1], finger_width,
            center1[tb1] - height / 2.0 + offsets[tb1], height)
          cut_or_grow(board1, dir1, rect, depth, false, finger_width * height * depth)

          rect = face_rect_world(board2.bounds, dir2,
            start2 + finger_width * i + offsets[ta2], finger_width,
            center2[tb2] - height / 2.0 + offsets[tb2], height)
          cut_or_grow(board2, dir2, rect, depth, true, finger_width * height * depth)
        end

        model.commit_operation
        { success: true, board1_id: board1.entityID, board2_id: board2.entityID }
      rescue Exception
        model.abort_operation
        raise
      end
    end

    def create_dovetail(params)
      log "Creating dovetail joint with params: #{params.inspect}"
      convert_joint_units!(params)
      tail_board = find_board(params["tail_id"], "Tail board")
      pin_board = find_board(params["pin_id"], "Pin board")

      width = params["width"] || 1.0
      height = params["height"] || 1.0
      depth = params["depth"] || 1.0
      angle = params["angle"] || 15.0
      num_tails = [(params["num_tails"] || 3).to_i, 1].max
      offsets = joint_offsets(params)

      model = Sketchup.active_model
      model.start_operation("MCP dovetail", true)
      begin
        direction = tail_board.bounds.center.vector_to(pin_board.bounds.center)
        tail_dir = determine_closest_face(direction)
        pin_dir = determine_closest_face(direction.reverse)
        tail_frame = FACE_FRAMES[tail_dir]
        pin_frame = FACE_FRAMES[pin_dir]

        # Tails occupy the even slots of a (2*num_tails - 1) division.
        slot_width = width / (2 * num_tails - 1)
        taper = depth * Math.tan(angle * Math::PI / 180.0)

        tail_center = tail_board.bounds.center.to_a
        pin_center = pin_board.bounds.center.to_a
        tail_start = tail_center[tail_frame[2]] - width / 2.0
        pin_start = pin_center[pin_frame[2]] - width / 2.0

        num_tails.times do |i|
          # Tail: straight protrusion, then the free end is stretched wider.
          rect = face_rect_world(tail_board.bounds, tail_dir,
            tail_start + slot_width * (2 * i) + offsets[tail_frame[2]], slot_width,
            tail_center[tail_frame[3]] - height / 2.0 + offsets[tail_frame[3]], height)
          face = cut_or_grow(tail_board, tail_dir, rect, depth, false, slot_width * height * depth)
          stretch_end_face(tail_board, tail_dir, rect, depth, taper)

          # Socket: straight slot into the pin board, inner end stretched
          # wider so it matches the tail.
          rect = face_rect_world(pin_board.bounds, pin_dir,
            pin_start + slot_width * (2 * i) + offsets[pin_frame[2]], slot_width,
            pin_center[pin_frame[3]] - height / 2.0 + offsets[pin_frame[3]], height)
          cut_or_grow(pin_board, pin_dir, rect, depth, true, slot_width * height * depth)
          stretch_end_face(pin_board, pin_dir, rect, depth, taper)
        end

        model.commit_operation
        { success: true, tail_id: tail_board.entityID, pin_id: pin_board.entityID }
      rescue Exception
        model.abort_operation
        raise
      end
    end

    def determine_closest_face(direction_vector)
      v = direction_vector.normalize
      x_abs = v.x.abs
      y_abs = v.y.abs
      z_abs = v.z.abs
      if x_abs >= y_abs && x_abs >= z_abs
        v.x > 0 ? :east : :west
      elsif y_abs >= x_abs && y_abs >= z_abs
        v.y > 0 ? :north : :south
      else
        v.z > 0 ? :top : :bottom
      end
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