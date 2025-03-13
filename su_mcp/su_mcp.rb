require 'sketchup'
require 'extensions'

module SU_MCP
  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new('Sketchup MCP', 'su_mcp/main')
    ext.description = 'MCP Server for Sketchup'
    ext.version     = '0.1.0'
    ext.creator     = 'MCP'
    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end 