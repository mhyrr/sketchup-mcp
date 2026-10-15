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

1. Start Sketchup. The extension starts its server automatically on the
   default port (9876); check the Ruby Console for "Server started and
   listening". If it failed (for example, the port was in use), use
   Extensions > MCP Server > Start Server to retry.
2. Make sure the MCP server is running in your terminal

### Connecting across a VM

The extension listens on `127.0.0.1:9876` by default, and the MCP server
connects to `localhost:9876`. If SketchUp runs in a VM and Claude runs on the
host, loopback will not work in either direction:

1. In the guest, set `SKETCHUP_MCP_BIND` to `0.0.0.0` (for example
   `setx SKETCHUP_MCP_BIND 0.0.0.0`, then restart SketchUp) so the incoming
   connection can arrive at all.
2. On the host, set `SKETCHUP_MCP_HOST` in the Claude config's `env` to the
   guest's address - `localhost` with VirtualBox NAT port forwarding, or the
   guest IP on a host-only or bridged network. `SKETCHUP_MCP_PORT` moves the
   port, and has to be set on both sides.

There is no authentication on that port and no approval prompt before
`eval_ruby` runs, so binding to `0.0.0.0` lets anything that can reach the
guest run Ruby in SketchUp. Only do it when the VM is disposable and the
network it sits on is one you trust.

### When it stops answering

Every request is logged to the Ruby Console as `Request #N started` and
`Request #N finished` (or `failed`). If calls start timing out, the last
`started` with no matching end is the one that never came back. **Extensions >
MCP Server > Show Status** prints the connected clients, the requests still in
flight, and when the server last serviced its sockets.

A request that never returns no longer blocks the others, and a watchdog
restarts the server's timer if it stops firing. `eval_ruby` gives up after 50
seconds, so it answers before the MCP client's own timeout does.
`SKETCHUP_MCP_EVAL_TIMEOUT` on the host changes that; keep it under the
client's limit.

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

Once connected, Claude can interact with Sketchup using the following capabilities:

#### Tools

* `get_scene_info` - Gets information about the current Sketchup scene
* `get_selected_components` - Gets information about currently selected components
* `create_component` - Create a new component with specified parameters
* `delete_component` - Remove a component from the scene
* `transform_component` - Move, rotate, or scale a component
* `set_material` - Apply materials to components
* `export_scene` - Export the current scene to various formats
* `eval_ruby` - Execute arbitrary Ruby code in SketchUp for advanced operations

### Example Commands

Here are some examples of what you can ask Claude to do:

* "Create a simple house model with a roof and windows"
* "Select all components and get their information"
* "Make the selected component red"
* "Move the selected component 10 units up"
* "Export the current scene as a 3D model"
* "Create a complex arts and crafts cabinet using Ruby code"

## Troubleshooting

* **Connection issues**: Make sure both the Sketchup extension server and the MCP server are running
* **Command failures**: Check the Ruby Console in Sketchup for error messages
* **Timeout errors**: Try simplifying your requests or breaking them into smaller steps

## Technical Details

### Communication Protocol

The system uses a simple JSON-based protocol over TCP sockets:

* **Commands** are sent as JSON objects with a `type` and optional `params`
* **Responses** are JSON objects with a `status` and `result` or `message`

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT 