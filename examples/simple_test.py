#!/usr/bin/env python3
"""
Simple Test for eval_ruby

This is a minimal test to verify that the eval_ruby feature works correctly.
"""

import json
import logging
from mcp.client import Client

# Configure logging
logging.basicConfig(level=logging.INFO, 
                   format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("SimpleRubyTest")

# Simple Ruby code to create a cube
CUBE_CODE = """
model = Sketchup.active_model
entities = model.active_entities

# Start an operation for undo
model.start_operation("Create Test Cube", true)

# Create a group for the cube
group = entities.add_group

# Create the bottom face
face = group.entities.add_face(
  [0, 0, 0],
  [10, 0, 0],
  [10, 10, 0],
  [0, 10, 0]
)

# Push/pull to create the cube
face.pushpull(10)

# End the operation
model.commit_operation

# Return the group ID
group.entityID.to_s
"""

def main():
    """Main function to test the eval_ruby feature."""
    # Connect to the MCP server
    client = Client("sketchup")
    
    # Check if the connection is successful
    if not client.is_connected:
        logger.error("Failed to connect to the SketchUp MCP server.")
        return
    
    logger.info("Connected to SketchUp MCP server.")
    
    # Evaluate the Ruby code
    logger.info("Creating a simple cube...")
    response = client.eval_ruby(code=CUBE_CODE)
    
    # Parse the response
    try:
        result = json.loads(response)
        if result.get("success"):
            logger.info(f"Cube created successfully! Group ID: {result.get('result')}")
        else:
            logger.error(f"Failed to create cube: {result.get('error')}")
    except json.JSONDecodeError:
        logger.error(f"Failed to parse response: {response}")
    
    logger.info("Test completed.")

if __name__ == "__main__":
    main() 