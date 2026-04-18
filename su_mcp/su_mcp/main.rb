require 'sketchup'
require 'json'
require 'socket'
require 'fileutils'
require 'timeout'
require 'logger'
require 'tmpdir'

puts "MCP Extension loading..."

module SU_MCP
  # JSON-RPC 2.0 error codes (canonical + custom -320xx range)
  ERR_PARSE         = -32700
  ERR_INVALID_REQ   = -32600
  ERR_METHOD        = -32601
  ERR_INVALID_PARAM = -32602
  ERR_INTERNAL      = -32603
  ERR_TRANSPORT     = -32000
  ERR_TIMEOUT       = -32001
  ERR_RUBY_EXC      = -32002

  # Log levels
  LOG_DEBUG = 0
  LOG_INFO  = 1
  LOG_WARN  = 2
  LOG_ERROR = 3
  LOG_NAMES = { LOG_DEBUG => "DEBUG", LOG_INFO => "INFO", LOG_WARN => "WARN", LOG_ERROR => "ERROR" }

  class Server
    DEFAULT_PORT          = 9876
    DEFAULT_TIMEOUT       = 60      # seconds, per request
    DEFAULT_EVAL_TIMEOUT  = 30      # seconds, per eval_ruby call
    POLL_INTERVAL         = 0.05    # seconds between select() polls
    READ_CHUNK            = 16384   # bytes per non-blocking read
    MAX_REQUEST_BYTES     = 8 * 1024 * 1024  # 8 MB hard cap

    VERSION = "2.0.0"

    def initialize(port: nil)
      @port        = (port || ENV['SKETCHUP_MCP_PORT'] || DEFAULT_PORT).to_i
      @server      = nil
      @running     = false
      @timer_id    = nil
      @clients     = []   # array of {sock:, buffer:, id: }
      @next_cid    = 1
      @log_level   = parse_log_level(ENV['SKETCHUP_MCP_LOG_LEVEL'] || 'INFO')
      @log_to_file = ENV['SKETCHUP_MCP_LOG_FILE']  # path, optional
      @verbose_console = ENV['SKETCHUP_MCP_VERBOSE_CONSOLE'] == '1'
      @request_timeout  = (ENV['SKETCHUP_MCP_TIMEOUT']      || DEFAULT_TIMEOUT).to_i
      @eval_timeout     = (ENV['SKETCHUP_MCP_EVAL_TIMEOUT'] || DEFAULT_EVAL_TIMEOUT).to_i

      SKETCHUP_CONSOLE.show rescue nil
    end

    def parse_log_level(str)
      case str.to_s.upcase
      when 'DEBUG' then LOG_DEBUG
      when 'INFO'  then LOG_INFO
      when 'WARN'  then LOG_WARN
      when 'ERROR' then LOG_ERROR
      else LOG_INFO
      end
    end

    # Leveled logger. Writes to console only if WARN+ or @verbose_console set.
    # Always appends to file if @log_to_file set.
    # Dual signature:
    #   log(level_int, msg_string)  — preferred
    #   log(msg_string)             — legacy, treated as DEBUG
    def log(level_or_msg, msg = nil)
      if msg.nil?
        level = LOG_DEBUG
        text = level_or_msg.to_s
      else
        level = level_or_msg
        text = msg.to_s
      end
      return if level < @log_level
      line = "[#{Time.now.strftime('%H:%M:%S')}] MCP #{LOG_NAMES[level]}: #{text}"
      if @verbose_console || level >= LOG_WARN
        begin
          SKETCHUP_CONSOLE.write(line + "\n")
        rescue
          puts line
        end
      end
      if @log_to_file
        begin
          File.open(@log_to_file, 'a') { |f| f.puts line }
        rescue
          # best effort
        end
      end
    end

    def debug(m); log(LOG_DEBUG, m); end
    def info(m);  log(LOG_INFO, m);  end
    def warn(m);  log(LOG_WARN, m);  end
    def error(m); log(LOG_ERROR, m); end

    def start
      return if @running

      begin
        info "Starting server v#{VERSION} on localhost:#{@port}"
        @server = TCPServer.new('127.0.0.1', @port)
        @running = true

        @timer_id = UI.start_timer(POLL_INTERVAL, true) { tick }
        info "Server listening on port #{@port} (timeout=#{@request_timeout}s, eval_timeout=#{@eval_timeout}s, log_level=#{LOG_NAMES[@log_level]})"
      rescue StandardError => e
        error "Startup failed: #{e.message}"
        error e.backtrace.first(5).join("\n")
        stop
      end
    end

    def stop
      info "Stopping server"
      @running = false

      UI.stop_timer(@timer_id) if @timer_id
      @timer_id = nil

      @clients.each do |c|
        begin c[:sock].close rescue nil end
      end
      @clients.clear

      @server.close rescue nil
      @server = nil
      info "Server stopped"
    end

    # Single tick of the UI timer: accept new connections, drain existing ones.
    def tick
      return unless @running
      accept_new_connections
      service_clients
    rescue StandardError => e
      error "tick error: #{e.message}"
      error e.backtrace.first(5).join("\n")
    end

    def accept_new_connections
      loop do
        ready = IO.select([@server], nil, nil, 0)
        break unless ready
        begin
          sock = @server.accept_nonblock
          cid = @next_cid
          @next_cid += 1
          @clients << { sock: sock, buffer: String.new(encoding: 'BINARY'), id: cid }
          debug "Client ##{cid} connected"
        rescue IO::WaitReadable, Errno::EAGAIN
          break
        end
      end
    end

    def service_clients
      @clients.reject! do |c|
        begin
          drain_client(c)
          false  # keep
        rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
          debug "Client ##{c[:id]} disconnected"
          begin c[:sock].close rescue nil end
          true   # drop
        rescue StandardError => e
          error "Client ##{c[:id]} error: #{e.message}"
          begin c[:sock].close rescue nil end
          true
        end
      end
    end

    # Read any pending bytes on the client socket, try to parse as many
    # JSON messages as possible, dispatch each one, and write responses.
    # Supports two framing modes:
    #   1. Concatenated JSON (accumulate buffer, try parse, on success consume prefix)
    #   2. Newline-delimited JSON (back-compat with v0.1.x clients)
    def drain_client(client)
      sock = client[:sock]

      loop do
        begin
          chunk = sock.read_nonblock(READ_CHUNK)
          if chunk.nil? || chunk.empty?
            raise EOFError
          end
          client[:buffer] << chunk
        rescue IO::WaitReadable, Errno::EAGAIN
          break  # no more data for now
        end

        if client[:buffer].bytesize > MAX_REQUEST_BYTES
          send_error(sock, nil, ERR_INVALID_REQ, "Request exceeds #{MAX_REQUEST_BYTES} bytes")
          client[:buffer].clear
          raise EOFError
        end
      end

      # Extract and dispatch all complete messages in buffer
      loop do
        break if client[:buffer].empty?
        request, consumed = try_parse_json_prefix(client[:buffer])
        break unless request  # need more data
        client[:buffer] = client[:buffer].byteslice(consumed, client[:buffer].bytesize - consumed) || String.new(encoding: 'BINARY')
        handle_and_respond(sock, request)
      end
    end

    # Try to parse a JSON object from the start of +buffer+.
    # Returns [parsed_hash, bytes_consumed] or [nil, 0] if incomplete/invalid.
    # Tolerates trailing whitespace/newlines between messages.
    def try_parse_json_prefix(buffer)
      text = buffer.dup.force_encoding('UTF-8')
      text.lstrip!
      return [nil, 0] if text.empty?

      # Fast path: newline-delimited
      if idx = text.index("\n")
        line = text[0..idx].strip
        if !line.empty?
          begin
            parsed = JSON.parse(line)
            consumed = buffer.bytesize - (text.bytesize - (idx + 1))
            return [parsed, consumed]
          rescue JSON::ParserError
            # fall through to incremental parse
          end
        end
      end

      # Slow path: incremental object parse
      depth = 0
      in_string = false
      escape = false
      text.each_char.with_index do |ch, i|
        if in_string
          if escape
            escape = false
          elsif ch == '\\'
            escape = true
          elsif ch == '"'
            in_string = false
          end
          next
        end
        case ch
        when '"' then in_string = true
        when '{' then depth += 1
        when '}' then
          depth -= 1
          if depth == 0
            candidate = text[0..i]
            begin
              parsed = JSON.parse(candidate)
              consumed = buffer.bytesize - (text.bytesize - (i + 1))
              return [parsed, consumed]
            rescue JSON::ParserError
              return [nil, 0]  # malformed — wait for more or treat as framing error
            end
          end
        end
      end
      [nil, 0]
    end

    def handle_and_respond(sock, request)
      req_id = request.is_a?(Hash) ? request["id"] : nil
      begin
        response = Timeout::timeout(@request_timeout) { handle_jsonrpc_request(request) }
        send_response(sock, response)
      rescue Timeout::Error
        warn "Request timeout (>#{@request_timeout}s)"
        send_error(sock, req_id, ERR_TIMEOUT, "Request timed out after #{@request_timeout}s")
      rescue StandardError => e
        error "Handler error: #{e.class}: #{e.message}"
        error e.backtrace.first(5).join("\n")
        send_error(sock, req_id, ERR_INTERNAL, e.message, backtrace: e.backtrace.first(5))
      end
    end

    def send_response(sock, response)
      body = response.to_json + "\n"
      sock.write(body)
      sock.flush
      debug "Sent #{body.bytesize} byte response"
    end

    def send_error(sock, id, code, message, data: nil, backtrace: nil)
      payload = {
        jsonrpc: "2.0",
        error: { code: code, message: message }.tap { |h|
          extra = {}
          extra[:backtrace] = backtrace if backtrace
          extra.merge!(data) if data.is_a?(Hash)
          h[:data] = extra unless extra.empty?
        },
        id: id
      }
      begin
        sock.write(payload.to_json + "\n")
        sock.flush
      rescue StandardError => e
        error "Failed to send error response: #{e.message}"
      end
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
        when "batch"
          batch(args)
        when "undo_last"
          undo_last(args)
        when "measure"
          measure(args)
        when "snapshot"
          snapshot(args)
        when "list_definitions"
          list_definitions(args)
        when "list_instances"
          list_instances(args)
        when "select"
          select_entities(args)
        when "units_info"
          units_info(args)
        when "transaction"
          transaction(args)
        when "ping"
          { success: true, result: { pong: true, version: VERSION, time: Time.now.to_f } }
        else
          raise "Unknown tool: #{tool_name}"
        end

        debug "Tool call result: #{result.inspect[0, 500]}"
        if result[:success]
          # Serialize payload appropriately:
          # - Hash payloads (e.g. new eval_ruby) → JSON text
          # - Scalars → to_s
          payload_text = case result[:result]
                        when nil  then "Success"
                        when Hash, Array then result[:result].to_json
                        else result[:result].to_s
                        end
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            result: {
              content: [{ type: "text", text: payload_text }],
              isError: false,
              success: true,
              resourceId: result[:id],
              structured: result[:result].is_a?(Hash) ? result[:result] : nil
            }.compact,
            id: request["id"]
          }
          debug "Sending success response (#{payload_text.bytesize} bytes)"
          response
        else
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            error: {
              code: ERR_INTERNAL,
              message: result[:error] || "Operation failed",
              data: { success: false }
            },
            id: request["id"]
          }
          debug "Sending error response (operation-failed)"
          response
        end
      rescue StandardError => e
        error "Tool call error: #{e.class}: #{e.message}"
        response = {
          jsonrpc: request["jsonrpc"] || "2.0",
          error: {
            code: ERR_RUBY_EXC,
            message: e.message,
            data: { success: false, backtrace: e.backtrace.first(5) }
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
    
    # ──────────────────────────────────────────────────────────────────
    # Phase B: batch & undo_last
    # ──────────────────────────────────────────────────────────────────

    # batch({ "calls": [{"tool": "eval_ruby", "args": {...}}, ...],
    #         "wrap_undo": true, "undo_name": "MCP batch", "stop_on_error": true })
    # Runs each sub-call inside ONE model.start_operation / commit_operation,
    # returning an array of per-call results. Any call that raises either
    # aborts the whole batch (stop_on_error) or is recorded as an error
    # entry and the batch continues.
    def batch(params)
      calls = Array(params["calls"])
      wrap_undo     = params["wrap_undo"] != false  # default true
      undo_name     = params["undo_name"] || "MCP batch"
      stop_on_error = params["stop_on_error"] != false

      results = []
      model = Sketchup.active_model

      runner = lambda do
        calls.each_with_index do |call, i|
          begin
            tool_name = call["tool"] || call[:tool]
            args      = call["args"] || call[:args] || {}
            sub_req = {
              "jsonrpc" => "2.0",
              "method"  => "tools/call",
              "params"  => { "name" => tool_name, "arguments" => args },
              "id"      => "batch-#{i}"
            }
            resp = handle_tool_call(sub_req)
            if resp[:error] || resp["error"]
              err = resp[:error] || resp["error"]
              msg = err[:message] || err["message"]
              results << { index: i, success: false, error: msg }
              raise "batch[#{i}] failed: #{msg}" if stop_on_error
            else
              payload = resp[:result] || resp["result"]
              results << { index: i, success: true, result: payload }
            end
          rescue StandardError => e
            results << { index: i, success: false, error: e.message }
            raise if stop_on_error
          end
        end
      end

      if wrap_undo && model
        model.start_operation(undo_name, true)
        begin
          runner.call
          model.commit_operation
        rescue StandardError => e
          model.abort_operation rescue nil
          return { success: false, error: e.message, result: { completed: results.size, results: results } }
        end
      else
        runner.call
      end

      { success: true, result: { count: results.size, results: results } }
    end

    # undo_last({ "steps": 1 }) — undo N operations in active model
    def undo_last(params)
      steps = (params && params["steps"] || 1).to_i
      steps = 1 if steps < 1
      model = Sketchup.active_model
      raise "No active model" unless model
      undone = 0
      steps.times do
        begin
          model.undo_operation
          undone += 1
        rescue StandardError
          break
        end
      end
      { success: true, result: { undone: undone, requested: steps } }
    end

    # ──────────────────────────────────────────────────────────────────
    # Phase C: new capability tools
    # ──────────────────────────────────────────────────────────────────

    # measure({ "id": 12345 }) — bounds + position + material + class
    def measure(params)
      entity_id = (params["id"] || params["entity_id"]).to_i
      model = Sketchup.active_model
      raise "No active model" unless model
      entity = model.find_entity_by_id(entity_id)
      raise "No entity with id=#{entity_id}" unless entity

      data = {
        id: entity_id,
        class: entity.class.name,
        valid: entity.valid?
      }
      if entity.respond_to?(:bounds)
        bb = entity.bounds
        data[:bounds_cm] = {
          min: bb.min.to_a.map { |v| (v.to_f / 0.393700787).round(3) },
          max: bb.max.to_a.map { |v| (v.to_f / 0.393700787).round(3) },
          size: [bb.width, bb.height, bb.depth].map { |v| (v.to_f / 0.393700787).round(3) }
        }
      end
      if entity.respond_to?(:transformation)
        o = entity.transformation.origin
        data[:position_cm] = o.to_a.map { |v| (v.to_f / 0.393700787).round(3) }
      end
      if entity.respond_to?(:material) && entity.material
        data[:material] = { name: entity.material.display_name, color: entity.material.color.to_a }
      end
      if entity.is_a?(Sketchup::ComponentInstance)
        data[:definition] = entity.definition.name
      elsif entity.is_a?(Sketchup::Group)
        data[:group_name] = entity.name
      end
      { success: true, result: data }
    end

    # snapshot({ "width": 1600, "height": 1000, "camera": {...optional...}, "antialias": true })
    # Renders the current view to a temp PNG and returns the absolute path
    # plus width/height. Base64 encoding skipped by default (large payload).
    def snapshot(params)
      params ||= {}
      width  = (params["width"]  || 1600).to_i
      height = (params["height"] || 1000).to_i
      antialias = params["antialias"] != false
      compression = (params["compression"] || 0.9).to_f
      path = params["path"] || File.join(Dir.tmpdir, "sketchup_mcp_snapshot_#{Time.now.to_i}.png")

      model = Sketchup.active_model
      view = model.active_view

      if params["camera"]
        cam_p = params["camera"]
        eye    = Geom::Point3d.new(*cam_p["eye"])    if cam_p["eye"]
        target = Geom::Point3d.new(*cam_p["target"]) if cam_p["target"]
        up_v   = Geom::Vector3d.new(*cam_p["up"])    if cam_p["up"]
        persp  = cam_p.fetch("perspective", true)
        fov    = cam_p["fov"] || 50.0
        if eye && target && up_v
          view.camera = Sketchup::Camera.new(eye, target, up_v, persp, fov)
        end
      end

      view.write_image(path, width, height, antialias, compression)
      { success: true, result: { path: path, width: width, height: height } }
    end

    # list_definitions({ "name_match": "Sofa", "include_bounds": true })
    def list_definitions(params)
      params ||= {}
      model = Sketchup.active_model
      raise "No active model" unless model
      match = params["name_match"]
      include_bounds = params["include_bounds"] != false

      results = model.definitions.map do |d|
        entry = {
          name: d.name,
          guid: (d.guid rescue nil),
          instance_count: d.count_instances,
          is_component: d.is_a?(Sketchup::ComponentDefinition)
        }
        if include_bounds
          bb = d.bounds
          entry[:bounds_cm] = {
            size: [bb.width, bb.height, bb.depth].map { |v| (v.to_f / 0.393700787).round(3) }
          }
        end
        entry
      end

      if match && !match.empty?
        rx = Regexp.new(match, Regexp::IGNORECASE)
        results = results.select { |e| rx.match?(e[:name].to_s) }
      end

      { success: true, result: { count: results.size, definitions: results } }
    end

    # list_instances({ "definition_name": "Single Sofa", "limit": 200,
    #                  "bounds": { "min": [x,y,z], "max": [x,y,z] } })
    def list_instances(params)
      params ||= {}
      model = Sketchup.active_model
      raise "No active model" unless model
      want_def = params["definition_name"]
      limit = (params["limit"] || 500).to_i
      bb_filter = params["bounds"]

      collected = []
      walker = lambda do |ents|
        ents.each do |e|
          break if collected.size >= limit
          case e
          when Sketchup::ComponentInstance
            if !want_def || e.definition.name == want_def
              bb = e.bounds
              if pass_bb_filter?(bb, bb_filter)
                collected << {
                  id: e.entityID,
                  definition: e.definition.name,
                  position_cm: e.transformation.origin.to_a.map { |v| (v.to_f / 0.393700787).round(3) },
                  bounds_min_cm: bb.min.to_a.map { |v| (v.to_f / 0.393700787).round(3) },
                  bounds_max_cm: bb.max.to_a.map { |v| (v.to_f / 0.393700787).round(3) }
                }
              end
            end
          when Sketchup::Group
            if !want_def || e.name == want_def
              bb = e.bounds
              if pass_bb_filter?(bb, bb_filter)
                collected << {
                  id: e.entityID,
                  group_name: e.name,
                  bounds_min_cm: bb.min.to_a.map { |v| (v.to_f / 0.393700787).round(3) },
                  bounds_max_cm: bb.max.to_a.map { |v| (v.to_f / 0.393700787).round(3) }
                }
              end
            end
          end
        end
      end
      walker.call(model.entities)

      { success: true, result: { count: collected.size, instances: collected, truncated: collected.size >= limit } }
    end

    def pass_bb_filter?(bb, filter)
      return true unless filter
      min = filter["min"]; max = filter["max"]
      return true unless min && max
      !(bb.max.x < min[0] || bb.min.x > max[0] ||
        bb.max.y < min[1] || bb.min.y > max[1] ||
        bb.max.z < min[2] || bb.min.z > max[2])
    end

    # select({ "ids": [1234, 5678] }) — replaces current selection
    def select_entities(params)
      params ||= {}
      model = Sketchup.active_model
      raise "No active model" unless model
      ids = Array(params["ids"]).map(&:to_i)
      model.selection.clear
      resolved = ids.map { |i| model.find_entity_by_id(i) }.compact
      model.selection.add(resolved)
      { success: true, result: { requested: ids.size, selected: resolved.size, missing: ids.size - resolved.size } }
    end

    # units_info — expose length unit + conversion factors so the client
    # never has to guess inches vs cm.
    def units_info(params)
      model = Sketchup.active_model
      raise "No active model" unless model
      opts = model.options["UnitsOptions"]
      names = { 0 => "inches", 1 => "feet", 2 => "mm", 3 => "cm", 4 => "m" }
      {
        success: true,
        result: {
          length_unit_code: opts["LengthUnit"],
          length_unit_name: names[opts["LengthUnit"]] || "unknown",
          inches_per_cm: 1.cm.to_f,
          cm_per_inch: (1.0 / 1.cm.to_f),
          model_title: model.title,
          model_path: model.path
        }
      }
    end

    # transaction({ "action": "start"|"commit"|"abort", "name": "...", "disable_ui": true })
    # Gives the client explicit control over undo boundaries when not using
    # the auto-wrap in eval_ruby / batch.
    def transaction(params)
      params ||= {}
      model = Sketchup.active_model
      raise "No active model" unless model
      action = (params["action"] || "start").downcase
      case action
      when "start", "begin"
        model.start_operation(params["name"] || "MCP transaction", params["disable_ui"] != false)
        { success: true, result: { action: "started" } }
      when "commit", "end"
        model.commit_operation
        { success: true, result: { action: "committed" } }
      when "abort", "rollback", "cancel"
        model.abort_operation
        { success: true, result: { action: "aborted" } }
      else
        raise "Unknown transaction action: #{action}"
      end
    end

    # ──────────────────────────────────────────────────────────────────

    def eval_ruby(params)
      code = params["code"].to_s
      timeout_s = (params["timeout"] || @eval_timeout).to_i
      wrap_undo = params["wrap_undo"] != false  # default true
      undo_name = params["undo_name"] || "MCP eval_ruby"

      debug "Evaluating Ruby code (#{code.bytesize} bytes, timeout=#{timeout_s}s, wrap_undo=#{wrap_undo})"

      begin
        eval_binding = TOPLEVEL_BINDING.dup
        raw_result = nil

        runner = lambda do
          raw_result = eval(code, eval_binding)
        end

        Timeout::timeout(timeout_s, Timeout::Error) do
          if wrap_undo && Sketchup.active_model
            Sketchup.active_model.start_operation(undo_name, true)
            begin
              runner.call
              Sketchup.active_model.commit_operation
            rescue StandardError
              Sketchup.active_model.abort_operation rescue nil
              raise
            end
          else
            runner.call
          end
        end

        debug "Code evaluation completed"

        # A5: structured result — try to JSON-serialize; fall back to inspect.
        value_json = begin
          JSON.generate(raw_result)
        rescue StandardError
          nil
        end

        {
          success: true,
          result: {
            value:   value_json,                    # nil if not JSON-serializable
            inspect: (raw_result.inspect[0, 10_000] rescue raw_result.to_s[0, 10_000]),
            class:   raw_result.class.name
          }
        }
      rescue Timeout::Error
        warn "eval_ruby timed out after #{timeout_s}s"
        raise "Ruby evaluation timed out after #{timeout_s}s (hint: pass {\"timeout\": N} to increase)"
      rescue StandardError => e
        error "eval_ruby error: #{e.message}"
        debug e.backtrace.first(10).join("\n")
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