import asyncio
import json
import logging
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any, AsyncIterator, Dict, List, Optional

from mcp.server.fastmcp import Context, FastMCP

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("SketchupMCPServer")

# Define version directly to avoid pkg_resources dependency
__version__ = "0.1.18"
logger.info(f"SketchupMCP Server version {__version__} starting up")


@dataclass
class AppContext:
    sketchup_connection: Optional['SketchupConnection'] = None


@dataclass
class SketchupConnection:
    host: str
    port: int
    reader: Optional[asyncio.StreamReader] = None
    writer: Optional[asyncio.StreamWriter] = None

    async def connect(self) -> bool:
        if self.writer and not self.writer.is_closing():
            return True
        try:
            self.reader, self.writer = await asyncio.open_connection(self.host, self.port)
            logger.info(f"Connected to Sketchup at {self.host}:{self.port}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect to Sketchup: {str(e)}")
            self.reader = None
            self.writer = None
            return False

    async def disconnect(self):
        if self.writer:
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except Exception as e:
                logger.error(f"Error disconnecting from Sketchup: {str(e)}")
            finally:
                self.writer = None
                self.reader = None

    async def send_command(self, method: str, params: Dict[str, Any] = None, request_id: Any = None) -> Dict[str, Any]:
        if not await self.connect():
            raise ConnectionError("Not connected to Sketchup")

        request = {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {"name": method, "arguments": params or {}},
            "id": request_id,
        }

        request_bytes = json.dumps(request).encode('utf-8') + b'\n'
        self.writer.write(request_bytes)
        await self.writer.drain()

        try:
            response_data = await asyncio.wait_for(self.reader.readline(), timeout=15.0)
            if not response_data:
                raise ConnectionError("Connection closed by Sketchup")
            response = json.loads(response_data.decode('utf-8'))
            if "error" in response:
                raise Exception(response["error"].get("message", "Unknown error from Sketchup"))
            return response.get("result", {})
        except asyncio.TimeoutError:
            await self.disconnect()
            raise ConnectionError("Timeout waiting for response from Sketchup")
        except Exception as e:
            await self.disconnect()
            raise


@asynccontextmanager
async def server_lifespan(server: FastMCP) -> AsyncIterator[AppContext]:
    """Manage server startup and shutdown lifecycle"""
    sketchup_connection = SketchupConnection(host="localhost", port=9876)
    app_context = AppContext(sketchup_connection=sketchup_connection)
    try:
        logger.info("SketchupMCP server starting up")
        await sketchup_connection.connect()
        yield app_context
    finally:
        if app_context.sketchup_connection:
            logger.info("Disconnecting from Sketchup")
            await app_context.sketchup_connection.disconnect()
        logger.info("SketchupMCP server shut down")


mcp = FastMCP(
    "SketchupMCP",
    instructions="Sketchup integration through the Model Context Protocol",
    lifespan=server_lifespan,
)


async def call_sketchup(ctx: Context[Any, AppContext], tool_name: str, **kwargs) -> Dict[str, Any]:
    sketchup = ctx.request_context.lifespan_context.sketchup_connection
    if not sketchup:
        raise ConnectionError("Not connected to Sketchup")
    try:
        return await sketchup.send_command(tool_name, kwargs, ctx.request_id)
    except Exception as e:
        logger.error(f"Error calling sketchup tool {tool_name}: {e}")
        # Attempt to reconnect
        await sketchup.disconnect()
        if await sketchup.connect():
             return await sketchup.send_command(tool_name, kwargs, ctx.request_id)
        raise e


@mcp.tool()
async def create_component(
    ctx: Context[Any, AppContext],
    type: str = "cube",
    position: Optional[List[float]] = None,
    dimensions: Optional[List[float]] = None,
) -> Dict[str, Any]:
    """Create a new component in Sketchup"""
    return await call_sketchup(
        ctx,
        "create_component",
        type=type,
        position=position or [0, 0, 0],
        dimensions=dimensions or [1, 1, 1],
    )


@mcp.tool()
async def delete_component(ctx: Context[Any, AppContext], id: str) -> Dict[str, Any]:
    """Delete a component by ID"""
    return await call_sketchup(ctx, "delete_component", id=id)


@mcp.tool()
async def transform_component(
    ctx: Context[Any, AppContext],
    id: str,
    position: Optional[List[float]] = None,
    rotation: Optional[List[float]] = None,
    scale: Optional[List[float]] = None,
) -> Dict[str, Any]:
    """Transform a component's position, rotation, or scale"""
    params = {"id": id}
    if position is not None:
        params["position"] = position
    if rotation is not None:
        params["rotation"] = rotation
    if scale is not None:
        params["scale"] = scale
    return await call_sketchup(ctx, "transform_component", **params)


@mcp.tool()
async def get_selection(ctx: Context[Any, AppContext]) -> Dict[str, Any]:
    """Get currently selected components"""
    return await call_sketchup(ctx, "get_selection")


@mcp.tool()
async def set_material(ctx: Context[Any, AppContext], id: str, material: str) -> Dict[str, Any]:
    """Set material for a component"""
    return await call_sketchup(ctx, "set_material", id=id, material=material)


@mcp.tool()
async def export_scene(ctx: Context[Any, AppContext], format: str = "skp") -> Dict[str, Any]:
    """Export the current scene"""
    return await call_sketchup(ctx, "export_scene", format=format)


@mcp.tool()
async def create_mortise_tenon(
    ctx: Context[Any, AppContext],
    mortise_id: str,
    tenon_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> Dict[str, Any]:
    """Create a mortise and tenon joint between two components"""
    return await call_sketchup(
        ctx,
        "create_mortise_tenon",
        mortise_id=mortise_id,
        tenon_id=tenon_id,
        width=width,
        height=height,
        depth=depth,
        offset_x=offset_x,
        offset_y=offset_y,
        offset_z=offset_z,
    )


@mcp.tool()
async def create_dovetail(
    ctx: Context[Any, AppContext],
    tail_id: str,
    pin_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    angle: float = 15.0,
    num_tails: int = 3,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> Dict[str, Any]:
    """Create a dovetail joint between two components"""
    return await call_sketchup(
        ctx,
        "create_dovetail",
        tail_id=tail_id,
        pin_id=pin_id,
        width=width,
        height=height,
        depth=depth,
        angle=angle,
        num_tails=num_tails,
        offset_x=offset_x,
        offset_y=offset_y,
        offset_z=offset_z,
    )


@mcp.tool()
async def create_finger_joint(
    ctx: Context[Any, AppContext],
    board1_id: str,
    board2_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    num_fingers: int = 5,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> Dict[str, Any]:
    """Create a finger joint (box joint) between two components"""
    return await call_sketchup(
        ctx,
        "create_finger_joint",
        board1_id=board1_id,
        board2_id=board2_id,
        width=width,
        height=height,
        depth=depth,
        num_fingers=num_fingers,
        offset_x=offset_x,
        offset_y=offset_y,
        offset_z=offset_z,
    )


@mcp.tool()
async def eval_ruby(ctx: Context[Any, AppContext], code: str) -> Dict[str, Any]:
    """Evaluate arbitrary Ruby code in Sketchup"""
    return await call_sketchup(ctx, "eval_ruby", code=code)


def main():
    mcp.run()


if __name__ == "__main__":
    main()