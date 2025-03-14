#!/usr/bin/env python3
"""
Arts and Crafts Cabinet Example

This example demonstrates how to use the eval_ruby feature to create
a complex arts and crafts style cabinet in SketchUp using Ruby code.
"""

import json
import logging
from mcp.client import Client

# Configure logging
logging.basicConfig(level=logging.INFO, 
                   format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("ArtsAndCraftsCabinetExample")

# Ruby code to create an arts and crafts cabinet
CABINET_RUBY_CODE = """
# Arts and Crafts Cabinet with Working Doors
# This script creates a stylish arts and crafts style cabinet with working doors
# that can be opened and closed using SketchUp's component functionality

def create_arts_and_crafts_cabinet
  # Get the active model and start an operation for undo purposes
  model = Sketchup.active_model
  model.start_operation("Create Arts and Crafts Cabinet", true)
  
  # Define cabinet dimensions (in inches)
  width = 36
  depth = 18
  height = 72
  thickness = 0.75
  
  # Create a new component definition for the cabinet
  cabinet_def = model.definitions.add("Arts and Crafts Cabinet")
  entities = cabinet_def.entities
  
  # Create the main cabinet box
  create_cabinet_box(entities, width, depth, height, thickness)
  
  # Add shelves
  shelf_positions = [height/3, 2*height/3]
  create_shelves(entities, width, depth, thickness, shelf_positions)
  
  # Create doors (as nested components that can swing open)
  create_doors(entities, width, depth, height, thickness)
  
  # Add decorative elements typical of arts and crafts style
  add_decorative_elements(entities, width, depth, height, thickness)
  
  # Place the component in the model
  point = Geom::Point3d.new(0, 0, 0)
  transform = Geom::Transformation.new(point)
  instance = model.active_entities.add_instance(cabinet_def, transform)
  
  # End the operation
  model.commit_operation
  
  # Return the component instance ID
  return instance.entityID
end

def create_cabinet_box(entities, width, depth, height, thickness)
  # Bottom
  bottom_points = [
    [0, 0, 0], 
    [width, 0, 0], 
    [width, depth, 0], 
    [0, depth, 0]
  ]
  bottom_face = entities.add_face(bottom_points)
  bottom_face.pushpull(-thickness)
  
  # Back
  back_points = [
    [0, depth, 0], 
    [width, depth, 0], 
    [width, depth, height], 
    [0, depth, height]
  ]
  back_face = entities.add_face(back_points)
  back_face.pushpull(-thickness)
  
  # Left side
  left_points = [
    [0, 0, 0], 
    [0, depth, 0], 
    [0, depth, height], 
    [0, 0, height]
  ]
  left_face = entities.add_face(left_points)
  left_face.pushpull(-thickness)
  
  # Right side
  right_points = [
    [width, 0, 0], 
    [width, depth, 0], 
    [width, depth, height], 
    [width, 0, height]
  ]
  right_face = entities.add_face(right_points)
  right_face.pushpull(thickness)
  
  # Top
  top_points = [
    [0, 0, height], 
    [width, 0, height], 
    [width, depth, height], 
    [0, depth, height]
  ]
  top_face = entities.add_face(top_points)
  top_face.pushpull(thickness)
end

def create_shelves(entities, width, depth, thickness, positions)
  positions.each do |z_pos|
    shelf_points = [
      [thickness, thickness, z_pos], 
      [width - thickness, thickness, z_pos], 
      [width - thickness, depth - thickness, z_pos], 
      [thickness, depth - thickness, z_pos]
    ]
    shelf_face = entities.add_face(shelf_points)
    shelf_face.pushpull(-thickness)
  end
end

def create_doors(entities, width, depth, height, thickness)
  # Define door dimensions
  door_width = (width - thickness) / 2
  door_height = height - 2 * thickness
  
  # Create left door as a component (so it can be animated)
  left_door_def = Sketchup.active_model.definitions.add("Left Cabinet Door")
  
  # Create the door geometry in the component
  door_entities = left_door_def.entities
  left_door_points = [
    [0, 0, 0], 
    [door_width, 0, 0], 
    [door_width, thickness, 0], 
    [0, thickness, 0]
  ]
  left_door_face = door_entities.add_face(left_door_points)
  left_door_face.pushpull(door_height)
  
  # Add door details
  add_door_details(door_entities, door_width, thickness, door_height)
  
  # Place the left door component
  left_hinge_point = Geom::Point3d.new(thickness, thickness, thickness)
  left_transform = Geom::Transformation.new(left_hinge_point)
  left_door_instance = entities.add_instance(left_door_def, left_transform)
  
  # Set the hinge axis for animation - using correct method for SketchUp 2025
  # The component behavior is already set by default
  left_door_instance.definition.behavior.snapto = 0 # No automatic snapping
  
  # Create right door (similar process)
  right_door_def = Sketchup.active_model.definitions.add("Right Cabinet Door")
  
  door_entities = right_door_def.entities
  right_door_points = [
    [0, 0, 0], 
    [door_width, 0, 0], 
    [door_width, thickness, 0], 
    [0, thickness, 0]
  ]
  right_door_face = door_entities.add_face(right_door_points)
  right_door_face.pushpull(door_height)
  
  # Add door details
  add_door_details(door_entities, door_width, thickness, door_height)
  
  # Place the right door component
  right_hinge_point = Geom::Point3d.new(width - thickness, thickness, thickness)
  right_transform = Geom::Transformation.new(right_hinge_point)
  right_door_instance = entities.add_instance(right_door_def, right_transform)
  
  # Set the hinge axis for animation (flipped compared to left door)
  # The component behavior is already set by default
  right_door_instance.definition.behavior.snapto = 0
end

def add_door_details(entities, width, thickness, height)
  # Add a decorative panel that's inset
  inset = thickness / 2
  panel_points = [
    [inset, -thickness/2, inset], 
    [width - inset, -thickness/2, inset], 
    [width - inset, -thickness/2, height - inset], 
    [inset, -thickness/2, height - inset]
  ]
  panel = entities.add_face(panel_points)
  panel.pushpull(-thickness/4)
  
  # Add a small handle
  handle_position = [width - 2 * inset, -thickness * 1.5, height / 2]
  handle_size = height / 20
  
  # Create a cylinder for the handle
  handle_circle = entities.add_circle(handle_position, [0, 1, 0], handle_size, 12)
  handle_face = entities.add_face(handle_circle)
  handle_face.pushpull(-thickness)
end

def add_decorative_elements(entities, width, depth, height, thickness)
  # Add characteristic arts and crafts style base
  base_height = 4
  
  # Create a slightly wider base
  base_extension = 1
  base_points = [
    [-base_extension, -base_extension, 0], 
    [width + base_extension, -base_extension, 0], 
    [width + base_extension, depth + base_extension, 0], 
    [-base_extension, depth + base_extension, 0]
  ]
  base_face = entities.add_face(base_points)
  base_face.pushpull(-base_height)
  
  # Add corbels in the arts and crafts style
  add_corbels(entities, width, depth, height, thickness)
  
  # Add crown detail at the top
  add_crown(entities, width, depth, height, thickness)
end

def add_corbels(entities, width, depth, height, thickness)
  # Add decorative corbels under the top
  corbel_height = 3
  corbel_depth = 2
  
  # Left front corbel
  left_corbel_points = [
    [thickness * 2, thickness, height - thickness - corbel_height],
    [thickness * 2 + corbel_depth, thickness, height - thickness - corbel_height],
    [thickness * 2 + corbel_depth, thickness, height - thickness],
    [thickness * 2, thickness, height - thickness]
  ]
  left_corbel = entities.add_face(left_corbel_points)
  left_corbel.pushpull(-thickness)
  
  # Right front corbel
  right_corbel_points = [
    [width - thickness * 2 - corbel_depth, thickness, height - thickness - corbel_height],
    [width - thickness * 2, thickness, height - thickness - corbel_height],
    [width - thickness * 2, thickness, height - thickness],
    [width - thickness * 2 - corbel_depth, thickness, height - thickness]
  ]
  right_corbel = entities.add_face(right_corbel_points)
  right_corbel.pushpull(-thickness)
end

def add_crown(entities, width, depth, height, thickness)
  # Add a simple crown molding at the top
  crown_height = 2
  crown_extension = 1.5
  
  crown_points = [
    [-crown_extension, -crown_extension, height + thickness],
    [width + crown_extension, -crown_extension, height + thickness],
    [width + crown_extension, depth + crown_extension, height + thickness],
    [-crown_extension, depth + crown_extension, height + thickness]
  ]
  crown_face = entities.add_face(crown_points)
  crown_face.pushpull(crown_height)
  
  # Add a slight taper to the crown
  taper_points = [
    [-crown_extension/2, -crown_extension/2, height + thickness + crown_height],
    [width + crown_extension/2, -crown_extension/2, height + thickness + crown_height],
    [width + crown_extension/2, depth + crown_extension/2, height + thickness + crown_height],
    [-crown_extension/2, depth + crown_extension/2, height + thickness + crown_height]
  ]
  taper_face = entities.add_face(taper_points)
  taper_face.pushpull(crown_height/2)
end

# Execute the function to create the cabinet
create_arts_and_crafts_cabinet
"""

def main():
    """Main function to create the arts and crafts cabinet in SketchUp."""
    # Connect to the MCP server
    client = Client("sketchup")
    
    # Check if the connection is successful
    if not client.is_connected:
        logger.error("Failed to connect to the SketchUp MCP server.")
        return
    
    logger.info("Connected to SketchUp MCP server.")
    
    # Evaluate the Ruby code to create the cabinet
    logger.info("Creating arts and crafts cabinet...")
    response = client.eval_ruby(code=CABINET_RUBY_CODE)
    
    # Parse the response
    try:
        result = json.loads(response)
        if result.get("success"):
            logger.info(f"Cabinet created successfully! Result: {result.get('result')}")
        else:
            logger.error(f"Failed to create cabinet: {result.get('error')}")
    except json.JSONDecodeError:
        logger.error(f"Failed to parse response: {response}")
    
    logger.info("Example completed.")

if __name__ == "__main__":
    main() 