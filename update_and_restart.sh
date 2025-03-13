#!/bin/bash

# Kill any existing sketchup-mcp processes
pkill -f "python -m sketchup_mcp"

# Update the package
pip install sketchup-mcp==0.1.15

# Start the server in the background
python -m sketchup_mcp &

# Wait a moment for the server to start
sleep 1

echo "Updated to sketchup-mcp 0.1.15 and restarted the server" 