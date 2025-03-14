#!/usr/bin/env python3
"""
Simple Ruby Eval Example

This example demonstrates the basic usage of the eval_ruby feature
to execute Ruby code in SketchUp.
"""

import json
import logging
from mcp.client import Client

# Configure logging
logging.basicConfig(level=logging.INFO, 
                   format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("SimpleRubyEvalExample")

# Simple Ruby code examples
EXAMPLES = [
    {
        "name": "Create a line",
        "code": """
            model = Sketchup.active_model
            entities = model.active_entities
            line = entities.add_line([0,0,0], [100,100,100])
            line.entityID
        """
    },
    {
        "name": "Create a cube",
        "code": """
            model = Sketchup.active_model
            entities = model.active_entities
            group = entities.add_group
            face = group.entities.add_face(
                [0, 0, 0],
                [10, 0, 0],
                [10, 10, 0],
                [0, 10, 0]
            )
            face.pushpull(10)
            group.entityID
        """
    },
    {
        "name": "Get model information",
        "code": """
            model = Sketchup.active_model
            info = {
                "filename": model.path,
                "title": model.title,
                "description": model.description,
                "entity_count": model.entities.size,
                "selection_count": model.selection.size
            }
            info.to_json
        """
    }
]

def main():
    """Main function to demonstrate the eval_ruby feature."""
    # Connect to the MCP server
    client = Client("sketchup")
    
    # Check if the connection is successful
    if not client.is_connected:
        logger.error("Failed to connect to the SketchUp MCP server.")
        return
    
    logger.info("Connected to SketchUp MCP server.")
    
    # Run each example
    for example in EXAMPLES:
        logger.info(f"Running example: {example['name']}")
        
        # Evaluate the Ruby code
        response = client.eval_ruby(code=example["code"])
        
        # Parse the response
        try:
            result = json.loads(response)
            if result.get("success"):
                logger.info(f"Result: {result.get('result')}")
            else:
                logger.error(f"Error: {result.get('error')}")
        except json.JSONDecodeError:
            logger.error(f"Failed to parse response: {response}")
        
        logger.info("-" * 40)
    
    logger.info("All examples completed.")

if __name__ == "__main__":
    main() 