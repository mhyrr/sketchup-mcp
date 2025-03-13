require 'sketchup.rb'
require 'extensions.rb'
require 'json'
require 'socket'

module SU_MCP
  unless file_loaded?(__FILE__)
    ex = SketchupExtension.new('Sketchup MCP', 'su_mcp/main')
    ex.description = 'MCP server for Sketchup that allows AI agents to control and manipulate scenes'
    ex.version     = '0.1.0'
    ex.copyright   = '2024'
    Sketchup.register_extension(ex, true)
    file_loaded(__FILE__)
  end
end 