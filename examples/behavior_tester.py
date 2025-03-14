#!/usr/bin/env python3
"""
Component Behavior Tester

This script specifically tests the component behavior methods in SketchUp 25.0.574.
"""

import json
import logging
from mcp.client import Client

# Configure logging
logging.basicConfig(level=logging.INFO, 
                   format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("BehaviorTester")

# Ruby code to test component behavior methods
BEHAVIOR_TEST_CODE = """
# Create a new model context
model = Sketchup.active_model
model.start_operation("Test Component Behavior", true)

# Create a new component definition
definition = model.definitions.add("Test Component")

# Get the behavior object
behavior = definition.behavior

# Get all methods available on the behavior object
all_methods = behavior.methods - Object.methods

# Test setting various behavior properties
results = {}

# Test common behavior properties
properties_to_test = [
  "snapto",
  "cuts_opening",
  "always_face_camera",
  "no_scale_tool",
  "shadows_face_sun",
  "is_component",
  "component?"
]

# Test each property
property_results = {}
for prop in properties_to_test
  begin
    # Try to get the property
    if behavior.respond_to?(prop)
      property_results[prop] = {
        "exists": true,
        "readable": true
      }
      
      # Try to set the property (for boolean properties, try setting to true)
      setter_method = prop + "="
      if behavior.respond_to?(setter_method)
        if prop == "snapto"
          behavior.send(setter_method, 0)
        else
          behavior.send(setter_method, true)
        end
        property_results[prop]["writable"] = true
      else
        property_results[prop]["writable"] = false
      end
    else
      property_results[prop] = {
        "exists": false
      }
    end
  rescue => e
    property_results[prop] = {
      "exists": true,
      "error": e.message
    }
  end
end

# End the operation
model.commit_operation

# Return the results
{
  "all_methods": all_methods.sort,
  "property_results": property_results
}.to_json
"""

def main():
    """Main function to test component behavior methods."""
    # Connect to the MCP server
    client = Client("sketchup")
    
    # Check if the connection is successful
    if not client.is_connected:
        logger.error("Failed to connect to the SketchUp MCP server.")
        return
    
    logger.info("Connected to SketchUp MCP server.")
    
    # Run the behavior test
    logger.info("Testing component behavior methods...")
    response = client.eval_ruby(code=BEHAVIOR_TEST_CODE)
    
    # Parse the response
    try:
        result = json.loads(response)
        if result.get("success"):
            # Parse the JSON result
            behavior_data = json.loads(result.get("result"))
            
            # Display all available methods
            logger.info("Available methods on Behavior object:")
            for method in behavior_data["all_methods"]:
                logger.info(f"  - {method}")
            
            # Display property test results
            logger.info("\nProperty test results:")
            for prop, prop_result in behavior_data["property_results"].items():
                if prop_result.get("exists"):
                    readable = prop_result.get("readable", False)
                    writable = prop_result.get("writable", False)
                    error = prop_result.get("error")
                    
                    status = []
                    if readable:
                        status.append("readable")
                    if writable:
                        status.append("writable")
                    
                    if error:
                        logger.info(f"  - {prop}: EXISTS but ERROR: {error}")
                    else:
                        logger.info(f"  - {prop}: EXISTS ({', '.join(status)})")
                else:
                    logger.info(f"  - {prop}: DOES NOT EXIST")
        else:
            logger.error(f"Error: {result.get('error')}")
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse response: {e}")
    
    logger.info("Testing completed.")

if __name__ == "__main__":
    main() 