#!/usr/bin/env python3
"""
Simple Test for eval_ruby

This is a minimal test to verify that the eval_ruby feature works correctly.
"""

import asyncio
import json
import logging
import os

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("SimpleRubyTest")

# Simple Ruby code to create a cube
CUBE_CODE = """
model = Sketchup.active_model
entities = model.active_entities
model.start_operation("Create Test Cube", true)
group = entities.add_group
face = group.entities.add_face([0,0,0], [10,0,0], [10,10,0], [0,10,0])
face.pushpull(10)
model.commit_operation
group.entityID.to_s
"""

async def main():
    """Main function to test the eval_ruby feature."""
    server_params = StdioServerParameters(
        command="uv",
        args=["run", "sketchup-mcp"],
        env={"UV_INDEX": os.environ.get("UV_INDEX", "")},
    )

    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            logger.info("Connected to SketchUp MCP server.")

            logger.info("Creating a simple cube...")
            result = await session.call_tool("eval_ruby", arguments={"code": CUBE_CODE})

            if result.isError:
                logger.error(f"Failed to create cube: {result.content}")
            else:
                logger.info(f"Cube created successfully! Result: {result.content}")
    
    logger.info("Test completed.")

if __name__ == "__main__":
    asyncio.run(main())