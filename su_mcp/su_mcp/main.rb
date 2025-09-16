require 'sketchup'
require 'json'
require 'socket'
require 'fileutils'

module SU_MCP
  class Server
    def initialize
      @port = 9876
      @server = nil
      @running = false
      @timer_id = nil
      SKETCHUP_CONSOLE.show rescue nil
    end

    def log(msg)
      puts "MCP: #{msg}"
      STDOUT.flush
    end

    def start
      return if @running
      begin
        log "Starting server on localhost:#{@port}..."
        @server = TCPServer.new('127.0.0.1', @port)
        @running = true
        @timer_id = UI.start_timer(0.1, true) { handle_connection }
        log "Server started and listening"
      rescue StandardError => e
        log "Error starting server: #{e.message}"
        stop
      end
    end

    def stop
      log "Stopping server..."
      @running = false
      UI.stop_timer(@timer_id) if @timer_id
      @server.close if @server
      @server = nil
      log "Server stopped"
    end

    private

    def handle_connection
      return unless @running
      client = @server.accept_nonblock
      handle_client(client)
    rescue IO::WaitReadable
      # No client waiting
    rescue StandardError => e
      log "Error in connection handler: #{e.message}"
    end

    def handle_client(client)
      log "Client connected"
      raw_data = client.gets
      return unless raw_data
      
      request = JSON.parse(raw_data)
      response = handle_request(request)
      client.write(response.to_json + "\n")
    rescue JSON::ParserError => e
      log "JSON Parse Error: #{e.message}"
      client.write({ jsonrpc: "2.0", error: { code: -32700, message: "Parse error" }, id: nil }.to_json + "\n")
    rescue StandardError => e
      log "Request handling error: #{e.message}"
      client.write({ jsonrpc: "2.0", error: { code: -32603, message: e.message }, id: request ? request["id"] : nil }.to_json + "\n")
    ensure
      client.close
      log "Client disconnected"
    end

    def handle_request(request)
      method = request["method"]
      params = request["params"]
      id = request["id"]

      unless method == "tools/call"
        return { jsonrpc: "2.0", error: { code: -32601, message: "Method not found" }, id: id }
      end

      tool_name = params["name"]
      args = params["arguments"]

      begin
        result = dispatch_tool(tool_name, args)
        { jsonrpc: "2.0", result: result, id: id }
      rescue StandardError => e
        log "Tool execution error: #{e.message}"
        { jsonrpc: "2.0", error: { code: -32602, message: "Invalid params", data: e.message }, id: id }
      end
    end

    def dispatch_tool(tool_name, args)
      case tool_name
      when "create_component" then create_component(args)
      when "delete_component" then delete_component(args)
      when "transform_component" then transform_component(args)
      when "get_selection" then get_selection
      when "export", "export_scene" then export_scene(args)
      when "set_material" then set_material(args)
      when "eval_ruby" then eval_ruby(args)
      else raise "Unknown tool: #{tool_name}"
      end
    end

    def create_component(params)
      model = Sketchup.active_model
      entities = model.active_entities
      pos = params["position"] || [0,0,0]
      dims = params["dimensions"] || [1,1,1]
      
      group = entities.add_group
      face = group.entities.add_face(
        [pos[0], pos[1], pos[2]],
        [pos[0] + dims[0], pos[1], pos[2]],
        [pos[0] + dims[0], pos[1] + dims[1], pos[2]],
        [pos[0], pos[1] + dims[1], pos[2]]
      )
      face.pushpull(dims[2])
      { id: group.entityID, success: true }
    end

    def delete_component(params)
      model = Sketchup.active_model
      entity = model.find_entity_by_id(params["id"].to_i)
      raise "Entity not found" unless entity
      entity.erase!
      { success: true }
    end

    def transform_component(params)
      model = Sketchup.active_model
      entity = model.find_entity_by_id(params["id"].to_i)
      raise "Entity not found" unless entity

      if params["position"]
        pos = params["position"]
        translation = Geom::Transformation.translation(Geom::Point3d.new(pos[0], pos[1], pos[2]))
        entity.transform!(translation)
      end

      if params["rotation"]
        rot = params["rotation"]
        x_rot = rot[0].degrees
        y_rot = rot[1].degrees
        z_rot = rot[2].degrees
        center = entity.bounds.center
        entity.transform!(Geom::Transformation.rotation(center, [1,0,0], x_rot)) if x_rot != 0
        entity.transform!(Geom::Transformation.rotation(center, [0,1,0], y_rot)) if y_rot != 0
        entity.transform!(Geom::Transformation.rotation(center, [0,0,1], z_rot)) if z_rot != 0
      end

      if params["scale"]
        scale = params["scale"]
        center = entity.bounds.center
        scaling = Geom::Transformation.scaling(center, scale[0], scale[1], scale[2])
        entity.transform!(scaling)
      end
      { success: true, id: entity.entityID }
    end

    def get_selection
      model = Sketchup.active_model
      selection = model.selection
      selected_entities = selection.map { |e| { id: e.entityID, type: e.typename.downcase } }
      { success: true, entities: selected_entities }
    end
    
    def export_scene(params)
      model = Sketchup.active_model
      format = params["format"] || "skp"
      temp_dir = File.join(ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir, "sketchup_exports")
      FileUtils.mkdir_p(temp_dir)
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
      filename = "sketchup_export_#{timestamp}.#{format}"
      export_path = File.join(temp_dir, filename)
      
      options = {
        :filename => export_path,
        :width => 1920,
        :height => 1080,
        :antialias => true,
        :transparent => (format == "png")
      }
      
      if format == "skp"
        model.save(export_path)
      else
        model.active_view.write_image(options)
      end
      
      { success: true, path: export_path, format: format }
    end
    
    def set_material(params)
      model = Sketchup.active_model
      entity = model.find_entity_by_id(params["id"].to_i)
      raise "Entity not found" unless entity

      material_name = params["material"]
      material = model.materials[material_name] || model.materials.add(material_name)
      
      if !material.color
          begin
            material.color = Sketchup::Color.new(material_name)
          rescue
             material.color = Sketchup::Color.new(184, 134, 72) # Default wood color
          end
      end

      if entity.respond_to?(:material=)
        entity.material = material
      elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
        entities.grep(Sketchup::Face).each { |face| face.material = material }
      end
      
      { success: true, id: entity.entityID }
    end
    
    def eval_ruby(params)
      result = eval(params["code"], TOPLEVEL_BINDING.dup)
      { success: true, result: result.to_s }
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