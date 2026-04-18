from mcp.server.fastmcp import FastMCP, Context
import socket
import json
import os
import threading
import logging
from dataclasses import dataclass, field
from contextlib import asynccontextmanager
from typing import AsyncIterator, Dict, Any, List, Optional, Tuple

# ───── Configuration (env-driven) ─────────────────────────────────────────
SKETCHUP_HOST    = os.environ.get("SKETCHUP_MCP_HOST", "localhost")
SKETCHUP_PORT    = int(os.environ.get("SKETCHUP_MCP_PORT", "9876"))
REQUEST_TIMEOUT  = float(os.environ.get("SKETCHUP_MCP_TIMEOUT", "60"))
LONG_TIMEOUT     = float(os.environ.get("SKETCHUP_MCP_LONG_TIMEOUT", "300"))
MAX_RETRIES      = int(os.environ.get("SKETCHUP_MCP_MAX_RETRIES", "2"))
READ_CHUNK       = int(os.environ.get("SKETCHUP_MCP_READ_CHUNK", "32768"))
LOG_LEVEL        = os.environ.get("SKETCHUP_MCP_LOG_LEVEL", "INFO").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("SketchupMCPServer")

__version__ = "2.0.0"
logger.info("SketchupMCP Server %s starting up", __version__)


# ───── Typed errors ───────────────────────────────────────────────────────
class SketchupError(Exception):
    """Base for all SketchUp MCP client errors."""


class SketchupServerNotRunningError(SketchupError):
    """Raised when the in-SketchUp MCP server plugin isn't listening."""

    def __init__(self, host: str, port: int):
        super().__init__(
            f"SketchUp MCP server is not running on {host}:{port}. "
            "In SketchUp: Extensions → MCP Server → Start Server"
        )
        self.host = host
        self.port = port


class SketchupTransportError(SketchupError):
    """Socket-level failure (connection dropped, timeout, partial read)."""


class SketchupTimeoutError(SketchupError):
    """Request exceeded the configured timeout."""


class SketchupRubyError(SketchupError):
    """Ruby raised an exception in the SketchUp plugin."""

    def __init__(self, message: str, backtrace: Optional[List[str]] = None, code: Optional[int] = None):
        super().__init__(message)
        self.backtrace = backtrace or []
        self.code = code


# ───── Connection class ───────────────────────────────────────────────────
@dataclass
class SketchupConnection:
    host: str = SKETCHUP_HOST
    port: int = SKETCHUP_PORT
    sock: Optional[socket.socket] = None
    buffer: bytes = b""
    _next_id: int = 1
    _lock: threading.Lock = field(default_factory=threading.Lock)

    # ───── Connection lifecycle ─────────────────────────────────────────
    def _fresh_socket(self) -> socket.socket:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return s

    def connect(self) -> None:
        """Open a connection, raising SketchupServerNotRunningError on refused."""
        if self.sock is not None:
            return
        try:
            self.sock = self._fresh_socket()
            self.sock.settimeout(5.0)
            self.sock.connect((self.host, self.port))
            self.sock.settimeout(None)
            self.buffer = b""
            logger.info("Connected to SketchUp at %s:%s", self.host, self.port)
        except ConnectionRefusedError as e:
            self.sock = None
            raise SketchupServerNotRunningError(self.host, self.port) from e
        except OSError as e:
            self.sock = None
            raise SketchupTransportError(f"Could not connect: {e}") from e

    def disconnect(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except Exception:
                pass
        self.sock = None
        self.buffer = b""

    def _ensure_connected(self) -> None:
        if self.sock is None:
            self.connect()

    # ───── Framing: read until a complete JSON object is in buffer ──────
    def _read_until_json(self, timeout: float) -> Dict[str, Any]:
        """
        Accumulate bytes on self.buffer until a complete JSON message is
        present. Handles newline-delimited and concatenated framing.
        Returns the parsed dict and consumes its bytes from the buffer.
        """
        assert self.sock is not None
        self.sock.settimeout(timeout)
        end_time: Optional[float] = None
        import time

        while True:
            # First, try to parse what's already in the buffer.
            parsed, consumed = self._try_parse_prefix(self.buffer)
            if parsed is not None:
                self.buffer = self.buffer[consumed:]
                return parsed

            # Read more data.
            try:
                chunk = self.sock.recv(READ_CHUNK)
            except socket.timeout as e:
                raise SketchupTimeoutError(f"Read timed out after {timeout}s") from e
            except (ConnectionResetError, BrokenPipeError, OSError) as e:
                raise SketchupTransportError(f"Connection dropped during read: {e}") from e

            if not chunk:
                raise SketchupTransportError("Server closed connection before response completed")

            self.buffer += chunk

    @staticmethod
    def _try_parse_prefix(buf: bytes) -> Tuple[Optional[Dict[str, Any]], int]:
        """
        Try to parse a single JSON object from the beginning of buf.
        Skips leading whitespace. Returns (parsed, bytes_consumed) or
        (None, 0) if more data is needed.
        """
        if not buf:
            return None, 0
        # Skip leading whitespace
        i = 0
        while i < len(buf) and buf[i:i+1] in (b" ", b"\t", b"\r", b"\n"):
            i += 1
        if i == len(buf):
            return None, 0

        # Fast path: newline-delimited
        nl = buf.find(b"\n", i)
        if nl != -1:
            candidate = buf[i:nl].strip()
            if candidate:
                try:
                    return json.loads(candidate.decode("utf-8")), nl + 1
                except json.JSONDecodeError:
                    pass  # fall through to depth scan

        # Depth-based scan for a complete {...} object
        depth = 0
        in_str = False
        escape = False
        j = i
        while j < len(buf):
            c = buf[j:j+1]
            if in_str:
                if escape:
                    escape = False
                elif c == b"\\":
                    escape = True
                elif c == b'"':
                    in_str = False
            else:
                if c == b'"':
                    in_str = True
                elif c == b"{":
                    depth += 1
                elif c == b"}":
                    depth -= 1
                    if depth == 0:
                        candidate = buf[i:j+1]
                        try:
                            return json.loads(candidate.decode("utf-8")), j + 1
                        except json.JSONDecodeError:
                            return None, 0
            j += 1
        return None, 0

    # ───── Send request, receive response ──────────────────────────────
    def _next_request_id(self) -> int:
        with self._lock:
            rid = self._next_id
            self._next_id += 1
            return rid

    def send_command(
        self,
        method: str,
        params: Optional[Dict[str, Any]] = None,
        request_id: Any = None,
        timeout: Optional[float] = None,
    ) -> Dict[str, Any]:
        """
        Send a JSON-RPC request and return the `result` field.
        Raises typed exceptions for all failure modes.
        """
        timeout = timeout or REQUEST_TIMEOUT

        # Build request
        if method == "tools/call" and params and "name" in params and "arguments" in params:
            request = {"jsonrpc": "2.0", "method": method, "params": params}
        else:
            request = {
                "jsonrpc": "2.0",
                "method": "tools/call",
                "params": {"name": method, "arguments": params or {}},
            }
        request["id"] = request_id if request_id is not None else self._next_request_id()

        # Serialize under lock so concurrent callers don't interleave bytes
        with self._lock:
            last_error: Optional[Exception] = None
            for attempt in range(MAX_RETRIES + 1):
                try:
                    self._ensure_connected()
                    wire = (json.dumps(request) + "\n").encode("utf-8")
                    logger.debug("→ %s (%d bytes, attempt %d)", method, len(wire), attempt + 1)
                    assert self.sock is not None
                    self.sock.sendall(wire)
                    response = self._read_until_json(timeout)
                    logger.debug("← %s (id=%s)", method, response.get("id"))

                    # Reject wrong-id responses (stale retry collision)
                    if response.get("id") not in (None, request["id"]):
                        logger.warning(
                            "Discarding response with mismatched id: got %s, want %s",
                            response.get("id"), request["id"],
                        )
                        continue  # try to read next message

                    if "error" in response:
                        err = response["error"]
                        raise SketchupRubyError(
                            err.get("message", "Unknown error"),
                            backtrace=(err.get("data") or {}).get("backtrace"),
                            code=err.get("code"),
                        )
                    return response.get("result", {})

                except SketchupServerNotRunningError:
                    raise  # user-actionable, don't retry
                except SketchupRubyError:
                    raise  # application-level, don't retry
                except (SketchupTransportError, SketchupTimeoutError) as e:
                    last_error = e
                    logger.warning("Attempt %d/%d failed: %s", attempt + 1, MAX_RETRIES + 1, e)
                    self.disconnect()
                    if attempt >= MAX_RETRIES:
                        break
                    # brief backoff
                    import time
                    time.sleep(0.1 * (attempt + 1))

            assert last_error is not None
            raise last_error


# ───── Global connection singleton ────────────────────────────────────────
_sketchup_connection: Optional[SketchupConnection] = None
_conn_lock = threading.Lock()


def get_sketchup_connection() -> SketchupConnection:
    """Return a connected singleton, lazily created. Thread-safe."""
    global _sketchup_connection
    with _conn_lock:
        if _sketchup_connection is None:
            _sketchup_connection = SketchupConnection()
        _sketchup_connection.connect()  # idempotent
        return _sketchup_connection


@asynccontextmanager
async def server_lifespan(server: FastMCP) -> AsyncIterator[Dict[str, Any]]:
    """Manage server startup and shutdown lifecycle."""
    logger.info("SketchupMCP server starting up")
    try:
        try:
            get_sketchup_connection()
            logger.info("Connected to SketchUp on startup")
        except SketchupServerNotRunningError as e:
            logger.warning(str(e))
        except SketchupTransportError as e:
            logger.warning("Transport error on startup: %s", e)
        yield {}
    finally:
        global _sketchup_connection
        with _conn_lock:
            if _sketchup_connection is not None:
                _sketchup_connection.disconnect()
                _sketchup_connection = None
        logger.info("SketchupMCP server shut down")


# Create MCP server with lifespan support
mcp = FastMCP(
    "SketchupMCP",
    instructions="SketchUp integration through the Model Context Protocol",
    lifespan=server_lifespan,
)

# Tool endpoints
@mcp.tool()
def create_component(
    ctx: Context,
    type: str = "cube",
    position: List[float] = None,
    dimensions: List[float] = None
) -> str:
    """Create a new component in Sketchup"""
    try:
        logger.info(f"create_component called with type={type}, position={position}, dimensions={dimensions}, request_id={ctx.request_id}")
        
        sketchup = get_sketchup_connection()
        
        params = {
            "name": "create_component",
            "arguments": {
                "type": type,
                "position": position or [0,0,0],
                "dimensions": dimensions or [1,1,1]
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
    format: str = "skp"
) -> str:
    """Export the current scene"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "export",
                "arguments": {
                    "format": format
                }
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error exporting scene: {str(e)}"

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
    offset_z: float = 0.0
) -> str:
    """Create a mortise and tenon joint between two components"""
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
                    "offset_z": offset_z
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
    offset_z: float = 0.0
) -> str:
    """Create a dovetail joint between two components"""
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
                    "offset_z": offset_z
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
    offset_z: float = 0.0
) -> str:
    """Create a finger joint (box joint) between two components"""
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
                    "offset_z": offset_z
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
    """Evaluate arbitrary Ruby code in Sketchup"""
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

# ──────────────────────────────────────────────────────────────────────────
# Phase B + C: new tools (batch, undo_last, measure, snapshot,
# list_definitions, list_instances, select, units_info, transaction)
# ──────────────────────────────────────────────────────────────────────────

def _text_of(result: Dict[str, Any]) -> str:
    """Extract the text payload from a SketchUp tool-call response."""
    content = result.get("content")
    if isinstance(content, list) and content:
        item = content[0]
        if isinstance(item, dict):
            return item.get("text", "")
    return ""


def _call(ctx: Context, tool: str, args: Optional[Dict[str, Any]] = None,
          timeout: Optional[float] = None) -> str:
    """Low-level call helper: returns JSON string of the tool response."""
    try:
        conn = get_sketchup_connection()
        result = conn.send_command(
            method="tools/call",
            params={"name": tool, "arguments": args or {}},
            request_id=ctx.request_id,
            timeout=timeout,
        )
        # Prefer the structured payload if present, else the text.
        structured = result.get("structured")
        if structured is not None:
            return json.dumps({"success": True, "result": structured})
        text = _text_of(result)
        return json.dumps({"success": True, "result": text})
    except SketchupServerNotRunningError as e:
        logger.error(str(e))
        return json.dumps({"success": False, "error": str(e), "kind": "server_not_running"})
    except SketchupRubyError as e:
        logger.error("Ruby error: %s", e)
        return json.dumps({"success": False, "error": str(e), "kind": "ruby_error",
                           "backtrace": e.backtrace, "code": e.code})
    except (SketchupTimeoutError, SketchupTransportError) as e:
        logger.error("Transport: %s", e)
        return json.dumps({"success": False, "error": str(e), "kind": "transport"})
    except Exception as e:
        logger.exception("Unexpected error in %s", tool)
        return json.dumps({"success": False, "error": str(e), "kind": "unexpected"})


@mcp.tool()
def batch(ctx: Context, calls: List[Dict[str, Any]],
          wrap_undo: bool = True, undo_name: str = "MCP batch",
          stop_on_error: bool = True) -> str:
    """Run multiple tool calls as one undo-wrapped transaction.

    Args:
        calls: List of {"tool": "<name>", "args": {...}} objects.
        wrap_undo: Wrap the whole batch in start_operation/commit_operation.
        undo_name: Label for the undo history entry.
        stop_on_error: If True, abort the whole batch on first failure.
    """
    return _call(ctx, "batch",
                 {"calls": calls, "wrap_undo": wrap_undo,
                  "undo_name": undo_name, "stop_on_error": stop_on_error},
                 timeout=LONG_TIMEOUT)


@mcp.tool()
def undo_last(ctx: Context, steps: int = 1) -> str:
    """Undo the last N operations on the active model."""
    return _call(ctx, "undo_last", {"steps": steps})


@mcp.tool()
def measure(ctx: Context, id: int) -> str:
    """Return bounds (cm), position, material, and class for an entity by id."""
    return _call(ctx, "measure", {"id": id})


@mcp.tool()
def snapshot(ctx: Context, width: int = 1600, height: int = 1000,
             camera: Optional[Dict[str, Any]] = None,
             antialias: bool = True, path: Optional[str] = None,
             compression: float = 0.9) -> str:
    """Render the active view to a PNG.

    Args:
        width, height: Output pixel dimensions.
        camera: Optional {eye: [x,y,z], target: [x,y,z], up: [x,y,z],
                          perspective: bool, fov: float}.
        antialias: Enable 2x AA.
        path: Destination path (default: temp file).
        compression: PNG compression 0..1.
    """
    args: Dict[str, Any] = {
        "width": width, "height": height,
        "antialias": antialias, "compression": compression,
    }
    if camera is not None:
        args["camera"] = camera
    if path is not None:
        args["path"] = path
    return _call(ctx, "snapshot", args, timeout=LONG_TIMEOUT)


@mcp.tool()
def list_definitions(ctx: Context, name_match: Optional[str] = None,
                     include_bounds: bool = True) -> str:
    """List all component definitions in the active model.

    Args:
        name_match: Case-insensitive regex to filter by name.
        include_bounds: Include per-definition bounds in cm.
    """
    args: Dict[str, Any] = {"include_bounds": include_bounds}
    if name_match is not None:
        args["name_match"] = name_match
    return _call(ctx, "list_definitions", args)


@mcp.tool()
def list_instances(ctx: Context, definition_name: Optional[str] = None,
                   limit: int = 500,
                   bounds: Optional[Dict[str, List[float]]] = None) -> str:
    """List instances (components + groups) in the active model.

    Args:
        definition_name: Exact definition/group name filter.
        limit: Max entries to return.
        bounds: Optional {"min":[x,y,z], "max":[x,y,z]} bbox filter (inches).
    """
    args: Dict[str, Any] = {"limit": limit}
    if definition_name is not None:
        args["definition_name"] = definition_name
    if bounds is not None:
        args["bounds"] = bounds
    return _call(ctx, "list_instances", args)


@mcp.tool()
def select(ctx: Context, ids: List[int]) -> str:
    """Replace the current SketchUp selection with the given entity IDs."""
    return _call(ctx, "select", {"ids": ids})


@mcp.tool()
def units_info(ctx: Context) -> str:
    """Return model length unit and conversion factors."""
    return _call(ctx, "units_info")


@mcp.tool()
def transaction(ctx: Context, action: str, name: str = "MCP transaction",
                disable_ui: bool = True) -> str:
    """Explicit undo-transaction control.

    Args:
        action: 'start', 'commit', or 'abort'.
        name: Undo label (start only).
        disable_ui: Disable UI refresh during operation (start only).
    """
    return _call(ctx, "transaction",
                 {"action": action, "name": name, "disable_ui": disable_ui})


@mcp.tool()
def ping(ctx: Context) -> str:
    """Cheap health check: returns server version and timestamp."""
    return _call(ctx, "ping")


def main():
    mcp.run()


if __name__ == "__main__":
    main()