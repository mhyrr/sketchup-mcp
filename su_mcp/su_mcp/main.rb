require 'sketchup'
require 'json'
require 'socket'

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
                client = @server.accept_nonblock
                log "Client accepted"
                
                data = client.gets
                log "Got data: #{data.inspect}"
                
                if data
                  begin
                    request = JSON.parse(data)
                    log "Processing request: #{request["method"]} (id: #{request["id"]})"
                    
                    response = handle_jsonrpc_request(request)
                    response_json = response.to_json + "\n"
                    
                    log "Sending response: #{response_json.strip}"
                    client.write(response_json)
                    client.flush
                    log "Response sent"
                  rescue JSON::ParserError => e
                    log "JSON parse error: #{e.message}"
                    error_response = {
                      jsonrpc: "2.0",
                      error: { code: -32700, message: "Parse error" },
                      id: nil
                    }.to_json + "\n"
                    client.write(error_response)
                    client.flush
                  rescue StandardError => e
                    log "Request error: #{e.message}"
                    error_response = {
                      jsonrpc: "2.0",
                      error: { code: -32603, message: e.message },
                      id: request ? request["id"] : nil
                    }.to_json + "\n"
                    client.write(error_response)
                    client.flush
                  end
                end
                
                client.close
                log "Client closed"
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
      # Handle direct command format
      if request["command"]
        return handle_tool_call({
          "method" => "tools/call",
          "params" => {
            "name" => request["command"],
            "arguments" => request["parameters"]
          },
          "id" => nil
        })
      end

      # Handle jsonrpc format
      case request["method"]
      when "tools/call"
        handle_tool_call(request)
      when "resources/list"
        {
          jsonrpc: "2.0",
          result: { resources: list_resources },
          id: request["id"]
        }
      when "prompts/list"
        {
          jsonrpc: "2.0",
          result: { prompts: [] },
          id: request["id"]
        }
      else
        {
          jsonrpc: "2.0",
          error: { code: -32601, message: "Method not found" },
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
        else
          raise "Unknown tool: #{tool_name}"
        end

        {
          jsonrpc: "2.0",
          result: result,
          id: request["id"]
        }
      rescue StandardError => e
        log "Tool call error: #{e.message}"
        {
          jsonrpc: "2.0",
          error: { code: -32603, message: e.message },
          id: request["id"]
        }
      end
    end

    def create_component(params)
      model = Sketchup.active_model
      entities = model.active_entities
      
      case params["type"]
      when "cube"
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
        
        { id: group.entityID }
      else
        raise "Unknown component type: #{params["type"]}"
      end
    end

    def delete_component(params)
      model = Sketchup.active_model
      entity = model.find_entity_by_id(params["id"])
      
      if entity
        entity.erase!
        { success: true }
      else
        raise "Entity not found"
      end
    end

    def transform_component(params)
      model = Sketchup.active_model
      entity = model.find_entity_by_id(params["id"])
      
      if entity
        if params["matrix"]
          transformation = Geom::Transformation.new(params["matrix"])
          entity.transform!(transformation)
        end
        { success: true }
      else
        raise "Entity not found"
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