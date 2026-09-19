from mcp.server.fastmcp import FastMCP, Context, Image
import socket
import json
import asyncio
import logging
import os
import tempfile
from dataclasses import dataclass
from contextlib import asynccontextmanager
from typing import AsyncIterator, Dict, Any, List

# Configure logging
logging.basicConfig(level=logging.INFO, 
                   format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("SketchupMCPServer")

# Define version directly to avoid pkg_resources dependency
__version__ = "0.1.21"
logger.info(f"SketchupMCP Server version {__version__} starting up")

@dataclass
class SketchupConnection:
    host: str
    port: int
    sock: socket.socket = None
    
    def connect(self) -> bool:
        """Connect to the Sketchup extension socket server"""
        if self.sock:
            try:
                # Test if connection is still alive
                self.sock.settimeout(0.1)
                self.sock.send(b'')
                return True
            except (socket.error, BrokenPipeError, ConnectionResetError):
                # Connection is dead, close it and reconnect
                logger.info("Connection test failed, reconnecting...")
                self.disconnect()
            
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.connect((self.host, self.port))
            logger.info(f"Connected to Sketchup at {self.host}:{self.port}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect to Sketchup: {str(e)}")
            self.sock = None
            return False
    
    def disconnect(self):
        """Disconnect from the Sketchup extension"""
        if self.sock:
            try:
                self.sock.close()
            except Exception as e:
                logger.error(f"Error disconnecting from Sketchup: {str(e)}")
            finally:
                self.sock = None

    def receive_full_response(self, sock, buffer_size=8192):
        """Receive the complete response, potentially in multiple chunks"""
        chunks = []
        sock.settimeout(120.0)
        
        try:
            while True:
                try:
                    chunk = sock.recv(buffer_size)
                    if not chunk:
                        if not chunks:
                            raise Exception("Connection closed before receiving any data")
                        break
                    
                    chunks.append(chunk)
                    
                    try:
                        data = b''.join(chunks)
                        json.loads(data.decode('utf-8'))
                        logger.info(f"Received complete response ({len(data)} bytes)")
                        return data
                    except json.JSONDecodeError:
                        continue
                except socket.timeout:
                    logger.warning("Socket timeout during chunked receive")
                    break
                except (ConnectionError, BrokenPipeError, ConnectionResetError) as e:
                    logger.error(f"Socket connection error during receive: {str(e)}")
                    raise
        except socket.timeout:
            logger.warning("Socket timeout during chunked receive")
        except Exception as e:
            logger.error(f"Error during receive: {str(e)}")
            raise
            
        if chunks:
            data = b''.join(chunks)
            logger.info(f"Returning data after receive completion ({len(data)} bytes)")
            try:
                json.loads(data.decode('utf-8'))
                return data
            except json.JSONDecodeError:
                raise Exception("Incomplete JSON response received")
        else:
            raise Exception("No data received")

    def send_command(self, method: str, params: Dict[str, Any] = None, request_id: Any = None) -> Dict[str, Any]:
        """Send a JSON-RPC request to Sketchup and return the response"""
        # Try to connect if not connected
        if not self.connect():
            raise ConnectionError("Not connected to Sketchup")
        
        # Ensure we're sending a proper JSON-RPC request
        if method == "tools/call" and params and "name" in params and "arguments" in params:
            # This is already in the correct format
            request = {
                "jsonrpc": "2.0",
                "method": method,
                "params": params,
                "id": request_id
            }
        else:
            # This is a direct command - convert to JSON-RPC
            command_name = method
            command_params = params or {}
            
            # Log the conversion
            logger.info(f"Converting direct command '{command_name}' to JSON-RPC format")
            
            request = {
                "jsonrpc": "2.0",
                "method": "tools/call",
                "params": {
                    "name": command_name,
                    "arguments": command_params
                },
                "id": request_id
            }
        
        # Maximum number of retries
        max_retries = 2
        retry_count = 0
        
        while retry_count <= max_retries:
            try:
                logger.info(f"Sending JSON-RPC request: {request}")
                
                # Log the exact bytes being sent
                request_bytes = json.dumps(request).encode('utf-8') + b'\n'
                logger.info(f"Raw bytes being sent: {request_bytes}")
                
                self.sock.sendall(request_bytes)
                logger.info(f"Request sent, waiting for response...")
                
                self.sock.settimeout(120.0)
                
                response_data = self.receive_full_response(self.sock)
                logger.info(f"Received {len(response_data)} bytes of data")
                
                response = json.loads(response_data.decode('utf-8'))
                logger.info(f"Response parsed: {response}")

                if not isinstance(response, dict):
                    return response

                if "error" in response:
                    logger.error(f"Sketchup error: {response['error']}")
                    raise Exception(response["error"].get("message", "Unknown error from Sketchup"))

                return response.get("result", {})
                
            except (socket.timeout, ConnectionError, BrokenPipeError, ConnectionResetError) as e:
                logger.warning(f"Connection error (attempt {retry_count+1}/{max_retries+1}): {str(e)}")
                retry_count += 1
                
                if retry_count <= max_retries:
                    logger.info(f"Retrying connection...")
                    self.disconnect()
                    if not self.connect():
                        logger.error("Failed to reconnect")
                        break
                else:
                    logger.error(f"Max retries reached, giving up")
                    self.sock = None
                    raise Exception(f"Connection to Sketchup lost after {max_retries+1} attempts: {str(e)}")
            
            except json.JSONDecodeError as e:
                logger.error(f"Invalid JSON response from Sketchup: {str(e)}")
                if 'response_data' in locals() and response_data:
                    logger.error(f"Raw response (first 200 bytes): {response_data[:200]}")
                raise Exception(f"Invalid response from Sketchup: {str(e)}")
            
            except Exception as e:
                logger.error(f"Error communicating with Sketchup: {str(e)}")
                self.sock = None
                raise Exception(f"Communication error with Sketchup: {str(e)}")

# Global connection management
_sketchup_connection = None

def get_sketchup_connection():
    """Get a fresh connection to Sketchup.

    The Ruby-side server handles exactly one request per TCP connection and
    then closes it, so a cached socket is always stale. The previous
    send-a-ping-but-never-read-the-reply probe poisoned the socket with an
    unread "Method not found" response that the next real command then
    consumed, so always open a new connection per call instead.
    """
    global _sketchup_connection

    if _sketchup_connection is not None:
        try:
            _sketchup_connection.disconnect()
        except Exception:
            pass

    _sketchup_connection = SketchupConnection(host="localhost", port=9876)
    if not _sketchup_connection.connect():
        logger.error("Failed to connect to Sketchup")
        _sketchup_connection = None
        raise Exception("Could not connect to Sketchup. Make sure the Sketchup extension is running.")
    logger.info("Created new connection to Sketchup")

    return _sketchup_connection

@asynccontextmanager
async def server_lifespan(server: FastMCP) -> AsyncIterator[Dict[str, Any]]:
    """Manage server startup and shutdown lifecycle"""
    try:
        logger.info("SketchupMCP server starting up")
        try:
            sketchup = get_sketchup_connection()
            # The Ruby-side server is one-request-per-connection; leaving this
            # warm-up socket open makes its blocking accept loop freeze SketchUp.
            sketchup.disconnect()
            logger.info("Successfully connected to Sketchup on startup (socket released)")
        except Exception as e:
            logger.warning(f"Could not connect to Sketchup on startup: {str(e)}")
            logger.warning("Make sure the Sketchup extension is running")
        yield {}
    finally:
        global _sketchup_connection
        if _sketchup_connection:
            logger.info("Disconnecting from Sketchup")
            _sketchup_connection.disconnect()
            _sketchup_connection = None
        logger.info("SketchupMCP server shut down")

# Create MCP server with lifespan support
mcp = FastMCP(
    "SketchupMCP",
    instructions="Sketchup integration through the Model Context Protocol",
    lifespan=server_lifespan
)

# Tool endpoints
@mcp.tool()
def create_component(
    ctx: Context,
    type: str = "cube",
    position: List[float] = None,
    dimensions: List[float] = None,
    unit: str = "inch"
) -> str:
    """Create a new component in Sketchup. unit: inch (default), mm, cm or m"""
    try:
        logger.info(f"create_component called with type={type}, position={position}, dimensions={dimensions}, unit={unit}, request_id={ctx.request_id}")

        sketchup = get_sketchup_connection()

        params = {
            "name": "create_component",
            "arguments": {
                "type": type,
                "position": position or [0,0,0],
                "dimensions": dimensions or [1,1,1],
                "unit": unit
            }
        }
        
        logger.info(f"Calling send_command with method='tools/call', params={params}, request_id={ctx.request_id}")
        
        result = sketchup.send_command(
            method="tools/call",
            params=params,
            request_id=ctx.request_id
        )
        
        logger.info(f"create_component result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in create_component: {str(e)}")
        return f"Error creating component: {str(e)}"

@mcp.tool()
def delete_component(
    ctx: Context,
    id: str
) -> str:
    """Delete a component by ID"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "delete_component",
                "arguments": {"id": id}
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error deleting component: {str(e)}"

@mcp.tool()
def transform_component(
    ctx: Context,
    id: str,
    position: List[float] = None,
    rotation: List[float] = None,
    scale: List[float] = None
) -> str:
    """Transform a component's position, rotation, or scale"""
    try:
        sketchup = get_sketchup_connection()
        arguments = {"id": id}
        if position is not None:
            arguments["position"] = position
        if rotation is not None:
            arguments["rotation"] = rotation
        if scale is not None:
            arguments["scale"] = scale
            
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "transform_component",
                "arguments": arguments
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error transforming component: {str(e)}"

@mcp.tool()
def get_selection(ctx: Context) -> str:
    """Get currently selected components"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "get_selection",
                "arguments": {}
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error getting selection: {str(e)}"

@mcp.tool()
def get_model_info(ctx: Context, id: str = None) -> str:
    """Inspect the Sketchup model. Without id: global summary (entity counts by
    type, model bounds, scenes, layers, materials, units, selection). With an
    entity id: details for that entity (bounds, layer, definition, volume,
    surface area, face/edge counts). Read-only."""
    try:
        sketchup = get_sketchup_connection()
        arguments = {}
        if id is not None:
            arguments["id"] = id
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "get_model_info",
                "arguments": arguments
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error getting model info: {str(e)}"

@mcp.tool()
def set_camera(
    ctx: Context,
    standard_view: str = None,
    eye: List[float] = None,
    target: List[float] = None,
    up: List[float] = None,
    fov: float = None,
    perspective: bool = True,
    zoom_extents: bool = False
) -> str:
    """Position the camera. standard_view: top/bottom/front/back/left/right/iso
    (centered on the model). Or pass explicit eye/target (required together) and
    optional up vector, in SketchUp inches. fov in degrees; perspective=False
    gives an orthographic view; zoom_extents=True fits the model after moving.
    Pair with export_scene(format='png') to capture from the new viewpoint."""
    try:
        sketchup = get_sketchup_connection()
        arguments = {"perspective": perspective, "zoom_extents": zoom_extents}
        if standard_view is not None:
            arguments["standard_view"] = standard_view
        if eye is not None and target is not None:
            arguments["eye"] = eye
            arguments["target"] = target
            if up is not None:
                arguments["up"] = up
        if fov is not None:
            arguments["fov"] = fov
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "set_camera",
                "arguments": arguments
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error setting camera: {str(e)}"

@mcp.tool()
def boolean_operation(
    ctx: Context,
    operation: str,
    target_id: str,
    tool_id: str,
    delete_originals: bool = False
) -> str:
    """Boolean operation between two groups/components: 'union', 'difference'
    (target minus tool) or 'intersection'. Distances/sizes are in SketchUp
    inches. Returns the result group's resourceId."""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "boolean_operation",
                "arguments": {
                    "operation": operation,
                    "target_id": target_id,
                    "tool_id": tool_id,
                    "delete_originals": delete_originals
                }
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error in boolean operation: {str(e)}"

@mcp.tool()
def set_material(
    ctx: Context,
    id: str,
    material: str
) -> str:
    """Set material for a component"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "set_material",
                "arguments": {
                    "id": id,
                    "material": material
                }
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error setting material: {str(e)}"

@mcp.tool()
def export_scene(
    ctx: Context,
    format: str = "skp",
    filepath: str = None,
    width: int = 1920,
    height: int = 1080
) -> str:
    """Export the current scene (skp/obj/dae/stl/png/jpg). filepath: absolute
    destination path (parent folders are created); omit for a timestamped
    file in the system temp directory. For image formats width/height set the
    viewport export size. skp exports use save_copy, so the working model's
    own path is never rebound."""
    try:
        sketchup = get_sketchup_connection()
        arguments = {
            "format": format,
            "width": width,
            "height": height
        }
        if filepath:
            arguments["filepath"] = filepath
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "export",
                "arguments": arguments
            },
            request_id=ctx.request_id
        )
        # Surface the export path so callers can actually find the file.
        response = {"success": True}
        if isinstance(result, dict):
            for key in ("path", "format"):
                if result.get(key):
                    response[key] = result[key]
        return json.dumps(response)
    except Exception as e:
        return f"Error exporting scene: {str(e)}"

@mcp.tool()
def get_viewport_screenshot(
    ctx: Context,
    width: int = 1600,
    height: int = 900
) -> Image:
    """Capture the current SketchUp 3D viewport and return it as an image,
    so you can see the model directly without reading files. Pair with
    set_camera to inspect from specific viewpoints."""
    temp_path = os.path.join(tempfile.gettempdir(), f"sketchup_screenshot_{os.getpid()}.png")
    try:
        sketchup = get_sketchup_connection()
        sketchup.send_command(
            method="tools/call",
            params={
                "name": "get_viewport_screenshot",
                "arguments": {
                    "filepath": temp_path,
                    "width": width,
                    "height": height
                }
            },
            request_id=ctx.request_id
        )
        if not os.path.exists(temp_path):
            raise Exception("Screenshot file was not created")
        with open(temp_path, "rb") as f:
            image_bytes = f.read()
        return Image(data=image_bytes, format="png")
    except Exception as e:
        logger.error(f"Error capturing screenshot: {str(e)}")
        raise Exception(f"Screenshot failed: {str(e)}")
    finally:
        try:
            os.remove(temp_path)
        except OSError:
            pass

@mcp.tool()
def get_addon_status(ctx: Context) -> str:
    """Lightweight health check: SketchUp version, platform, Pro status,
    current model title/path and entity count, bridge port and uptime.
    Use this to verify the SketchUp extension is reachable before doing
    anything else."""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "get_addon_status",
                "arguments": {}
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error getting addon status: {str(e)}"

@mcp.tool()
def create_mortise_tenon(
    ctx: Context,
    mortise_id: str,
    tenon_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
    unit: str = "inch"
) -> str:
    """Create a mortise and tenon joint between two boards. The mortise board
    gets a rectangular hole, the tenon board a matching projection, on the
    faces nearest each other. unit: inch (default), mm, cm, m. Boards must be
    solids; each is replaced by the jointed result (new entity ids returned)."""
    try:
        logger.info(f"create_mortise_tenon called with mortise_id={mortise_id}, tenon_id={tenon_id}, width={width}, height={height}, depth={depth}, offsets=({offset_x}, {offset_y}, {offset_z})")
        
        sketchup = get_sketchup_connection()
        
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "create_mortise_tenon",
                "arguments": {
                    "mortise_id": mortise_id,
                    "tenon_id": tenon_id,
                    "width": width,
                    "height": height,
                    "depth": depth,
                    "offset_x": offset_x,
                    "offset_y": offset_y,
                    "offset_z": offset_z,
                    "unit": unit
                }
            },
            request_id=ctx.request_id
        )
        
        logger.info(f"create_mortise_tenon result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in create_mortise_tenon: {str(e)}")
        return f"Error creating mortise and tenon joint: {str(e)}"

@mcp.tool()
def create_dovetail(
    ctx: Context,
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
    unit: str = "inch"
) -> str:
    """Create a dovetail joint between two boards: trapezoidal tails added to
    the tail board, matching sockets cut from the pin board. angle in degrees.
    unit: inch (default), mm, cm, m. Boards are replaced by jointed results."""
    try:
        logger.info(f"create_dovetail called with tail_id={tail_id}, pin_id={pin_id}, width={width}, height={height}, depth={depth}, angle={angle}, num_tails={num_tails}")
        
        sketchup = get_sketchup_connection()
        
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "create_dovetail",
                "arguments": {
                    "tail_id": tail_id,
                    "pin_id": pin_id,
                    "width": width,
                    "height": height,
                    "depth": depth,
                    "angle": angle,
                    "num_tails": num_tails,
                    "offset_x": offset_x,
                    "offset_y": offset_y,
                    "offset_z": offset_z,
                    "unit": unit
                }
            },
            request_id=ctx.request_id
        )
        
        logger.info(f"create_dovetail result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in create_dovetail: {str(e)}")
        return f"Error creating dovetail joint: {str(e)}"

@mcp.tool()
def create_finger_joint(
    ctx: Context,
    board1_id: str,
    board2_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    num_fingers: int = 5,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
    unit: str = "inch"
) -> str:
    """Create a finger joint (box joint): fingers added across board1's near
    face, matching slots cut into board2, so the boards interlock. unit: inch
    (default), mm, cm, m. Boards are replaced by jointed results."""
    try:
        logger.info(f"create_finger_joint called with board1_id={board1_id}, board2_id={board2_id}, width={width}, height={height}, depth={depth}, num_fingers={num_fingers}")
        
        sketchup = get_sketchup_connection()
        
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "create_finger_joint",
                "arguments": {
                    "board1_id": board1_id,
                    "board2_id": board2_id,
                    "width": width,
                    "height": height,
                    "depth": depth,
                    "num_fingers": num_fingers,
                    "offset_x": offset_x,
                    "offset_y": offset_y,
                    "offset_z": offset_z,
                    "unit": unit
                }
            },
            request_id=ctx.request_id
        )
        
        logger.info(f"create_finger_joint result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in create_finger_joint: {str(e)}")
        return f"Error creating finger joint: {str(e)}"

@mcp.tool()
def eval_ruby(
    ctx: Context,
    code: str
) -> str:
    """Evaluate arbitrary Ruby code in Sketchup — use this for anything without
    a dedicated tool. Common recipes (m = Sketchup.active_model):
    - save: m.save('/path/model.skp') | non-destructive copy: m.save_copy('/path/copy.skp')
    - undo/redo: m.undo | m.redo
    - tag/layer: l = m.layers.add('Walls'); m.active_layer = l; entity.layer = l
    - scene/page: m.pages.add('Scene 1'); m.pages.selected_page = m.pages['Scene 1']
    - import file: m.import('/path/file.dwg') (supports dwg/dxf/ifc/kmz/3ds/stl/images)
    - follow-me (loft): face.followme(path_edges)
    - offset face: face.offset(2.0) # inches
    - shadows: s = m.shadow_info; s['ShadowDate']='2026/06/21'; s['ShadowTime']='14:00:00'
    - display toggles: m.rendering_options['DisplayShadows'] = true
    - arc/curve/ngon/text: entities.add_arc / add_curve / add_ngon / add_3d_text
    Runs inside one undoable operation; if the code raises, changes roll back."""
    try:
        logger.info(f"eval_ruby called with code length: {len(code)}")
        
        sketchup = get_sketchup_connection()
        
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "eval_ruby",
                "arguments": {
                    "code": code
                }
            },
            request_id=ctx.request_id
        )
        
        logger.info(f"eval_ruby result: {result}")
        
        # Format the response to include the result
        response = {
            "success": True,
            "result": result.get("content", [{"text": "Success"}])[0].get("text", "Success") if isinstance(result.get("content"), list) and len(result.get("content", [])) > 0 else "Success"
        }
        
        return json.dumps(response)
    except Exception as e:
        logger.error(f"Error in eval_ruby: {str(e)}")
        return json.dumps({
            "success": False,
            "error": str(e)
        })

def main():
    mcp.run()

if __name__ == "__main__":
    main()