# SketchupMCP - Sketchup Model Context Protocol Integration

SketchupMCP connects Sketchup to Claude AI through the Model Context Protocol (MCP), allowing Claude to directly interact with and control Sketchup. This integration enables prompt-assisted 3D modeling, scene creation, and manipulation in Sketchup.

Big Shoutout to [Blender MCP](https://github.com/ahujasid/blender-mcp) for the inspiration and structure.

## Features

* **Two-way communication**: Connect Claude AI to Sketchup through a TCP socket connection
* **Component manipulation**: Create, modify, delete, and transform components in Sketchup
* **Material control**: Apply and modify materials and colors
* **Scene inspection**: Get detailed information about the current Sketchup scene
* **Selection handling**: Get and manipulate selected components
* **Ruby code evaluation**: Execute arbitrary Ruby code directly in SketchUp for advanced operations

## Components

The system consists of two main components:

1. **Sketchup Extension**: A Sketchup extension that creates a TCP server within Sketchup to receive and execute commands
2. **MCP Server (`sketchup_mcp/server.py`)**: A Python server that implements the Model Context Protocol and connects to the Sketchup extension

## Installation

### Python Packaging

We're using uv so you'll need to ```brew install uv```

### Sketchup Extension

1. Download or build the latest `.rbz` file
2. In Sketchup, go to Window > Extension Manager
3. Click "Install Extension" and select the downloaded `.rbz` file
4. Restart Sketchup

## Usage

### Starting the Connection

1. In Sketchup, go to Extensions > SketchupMCP > Start Server
2. The server will start on the default port (9876)
3. Make sure the MCP server is running in your terminal

### Using with Claude

Configure Claude to use the MCP server by adding the following to your Claude configuration:

```json
    "mcpServers": {
        "sketchup": {
            "command": "uvx",
            "args": [
                "sketchup-mcp"
            ]
        }
    }
```

This will pull the [latest from PyPI](https://pypi.org/project/sketchup-mcp/)

Once connected, Claude can interact with SketchUp using the following capabilities.

#### Geometry tools (unchanged from 1.x)

* `create_component` — create a cube / cylinder / sphere / cone at a position
* `delete_component` — remove a component from the scene
* `transform_component` — move / rotate / scale a component
* `set_material` — apply a material / colour to an entity
* `get_selection` — inspect currently-selected entities
* `export_scene` — export to OBJ / DAE / STL / PNG / PDF / etc.
* `create_mortise_tenon`, `create_dovetail`, `create_finger_joint` — joinery helpers
* `eval_ruby` — execute arbitrary Ruby in SketchUp for advanced operations

#### New in 2.0

* `batch` — run a list of tool calls under ONE undo operation, one round-trip
* `undo_last` — programmatic `model.undo_operation`
* `measure` — structured bounds / position / material by entity ID (cm units)
* `snapshot` — set camera + render PNG in one call
* `list_definitions` — enumerate component definitions with counts + bounds
* `list_instances` — enumerate instances filtered by definition or bbox
* `select` — set `model.selection` by entity IDs
* `units_info` — report model length unit + cm↔inch conversion factors
* `transaction` — explicit `start` / `commit` / `abort` for multi-call workflows
* `ping` — health check (version + timestamp)

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `SKETCHUP_MCP_HOST` | `localhost` | Hostname for Python → Ruby socket |
| `SKETCHUP_MCP_PORT` | `9876` | TCP port for the Ruby plugin |
| `SKETCHUP_MCP_TIMEOUT` | `60` | Per-request timeout (s) |
| `SKETCHUP_MCP_LONG_TIMEOUT` | `300` | Timeout for `batch` / `snapshot` (s) |
| `SKETCHUP_MCP_EVAL_TIMEOUT` | `30` | Default `eval_ruby` timeout (s) |
| `SKETCHUP_MCP_MAX_RETRIES` | `2` | Transport-error retries |
| `SKETCHUP_MCP_READ_CHUNK` | `32768` | Socket read chunk size (bytes) |
| `SKETCHUP_MCP_LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARN` / `ERROR` |
| `SKETCHUP_MCP_LOG_FILE` | unset | Optional absolute path for Ruby-side log |
| `SKETCHUP_MCP_VERBOSE_CONSOLE` | unset | Set to `1` to echo DEBUG/INFO to SketchUp console |

### Example Commands

* "Create a simple house model with a roof and windows"
* "Select all components and get their information"
* "Make the selected component red"
* "Move the selected component 10 units up"
* "Export the current scene as a 3D model"
* "Create a complex arts-and-crafts cabinet using Ruby code"
* "Use `batch` to place 100 chairs in a semicircle around the stage"
* "`snapshot` the current camera to a 1920×1080 PNG"
* "List every component definition whose name matches `/sofa/i`"

## Troubleshooting

* **"SketchUp MCP server is not running"** — open SketchUp and choose
  Extensions → MCP Server → Start Server. This message means the TCP
  connection was refused on `localhost:9876`.
* **Timeouts** — set `SKETCHUP_MCP_TIMEOUT=120` for heavy scripts, or
  pass `{"timeout": 120}` to `eval_ruby` for a single long call.
* **Ruby errors** — the error response now includes `data.backtrace`
  (first 5 frames). Check your Ruby code or inspect the SketchUp
  Ruby Console for more context.
* **Upgrading from 0.1.x** — existing clients keep working.
  `eval_ruby` now returns `{value, inspect, class}`; legacy clients
  should fall back to the `inspect` field.

## Technical Details

### Communication Protocol

JSON-RPC 2.0 over TCP. The plugin accepts both newline-delimited and
concatenated-object framing and responds with newline-terminated JSON
objects. Error responses follow the JSON-RPC 2.0 shape:

```json
{"jsonrpc": "2.0", "error": {"code": -32002, "message": "...",
 "data": {"backtrace": ["main.rb:123:in `foo'", ...]}}, "id": 42}
```

Error codes:

| Code | Meaning |
|---|---|
| `-32700` | Parse error |
| `-32600` | Invalid request |
| `-32601` | Method not found |
| `-32602` | Invalid params |
| `-32603` | Internal error |
| `-32000` | Transport error |
| `-32001` | Timeout |
| `-32002` | Ruby exception (with backtrace) |

### Smoke test

`python scripts/smoke_test.py` exercises 15 failure modes against a
running SketchUp + plugin. Returns exit code = number of failures.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT 