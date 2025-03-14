#!/usr/bin/env python3
"""
Ruby Code Tester

This script tests Ruby code in smaller chunks to identify compatibility issues with SketchUp.
"""

import json
import logging
from mcp.client import Client

# Configure logging
logging.basicConfig(level=logging.INFO, 
                   format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("RubyTester")

# Test cases - each with a name and Ruby code to test
TEST_CASES = [
    {
        "name": "Basic Model Access",
        "code": """
            model = Sketchup.active_model
            entities = model.active_entities
            "Success: Basic model access works"
        """
    },
    {
        "name": "Create Group",
        "code": """
            model = Sketchup.active_model
            entities = model.active_entities
            group = entities.add_group
            group.entityID.to_s
        """
    },
    {
        "name": "Create Face and Pushpull",
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
            "Success: Created face and pushpull"
        """
    },
    {
        "name": "Component Definition",
        "code": """
            model = Sketchup.active_model
            definition = model.definitions.add("Test Component")
            definition.name
        """
    },
    {
        "name": "Component Behavior",
        "code": """
            model = Sketchup.active_model
            definition = model.definitions.add("Test Component")
            # Get behavior properties
            behavior = definition.behavior
            
            # Test available methods
            methods = behavior.methods - Object.methods
            
            # Return the available methods
            methods.sort.join(", ")
        """
    },
    {
        "name": "Component Instance",
        "code": """
            model = Sketchup.active_model
            entities = model.active_entities
            definition = model.definitions.add("Test Component")
            
            # Create a point and transformation
            point = Geom::Point3d.new(0, 0, 0)
            transform = Geom::Transformation.new(point)
            
            # Add instance
            instance = entities.add_instance(definition, transform)
            
            # Set behavior properties
            behavior = instance.definition.behavior
            behavior.snapto = 0
            
            "Success: Component instance created with behavior set"
        """
    }
]

def test_ruby_code(client, test_case):
    """Test a single Ruby code snippet."""
    logger.info(f"Testing: {test_case['name']}")
    
    response = client.eval_ruby(code=test_case["code"])
    
    try:
        result = json.loads(response)
        if result.get("success"):
            logger.info(f"✅ SUCCESS: {result.get('result')}")
            return True
        else:
            logger.error(f"❌ ERROR: {result.get('error')}")
            return False
    except json.JSONDecodeError:
        logger.error(f"Failed to parse response: {response}")
        return False

def main():
    """Main function to test Ruby code snippets."""
    # Connect to the MCP server
    client = Client("sketchup")
    
    # Check if the connection is successful
    if not client.is_connected:
        logger.error("Failed to connect to the SketchUp MCP server.")
        return
    
    logger.info("Connected to SketchUp MCP server.")
    logger.info("=" * 50)
    
    # Run each test case
    success_count = 0
    for test_case in TEST_CASES:
        if test_ruby_code(client, test_case):
            success_count += 1
        logger.info("-" * 50)
    
    # Summary
    logger.info(f"Testing complete: {success_count}/{len(TEST_CASES)} tests passed")

if __name__ == "__main__":
    main() 