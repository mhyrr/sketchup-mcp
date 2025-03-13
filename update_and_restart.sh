#!/bin/bash

# Stop any running MCP server
pkill -f sketchup-mcp || true

# Install the latest version
pip install sketchup-mcp==0.1.13

# Start the MCP server in the background
sketchup-mcp &

echo "Updated to sketchup-mcp 0.1.13 and restarted the server" 