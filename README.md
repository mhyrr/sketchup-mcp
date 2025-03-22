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

## Installation and Setup

### Using Nix (Recommended)

We provide a Nix flake for easy setup of the development environment:

1. **Prerequisites**:
   - Install [Nix](https://nixos.org/download.html) with flakes enabled
   - Optionally install [direnv](https://direnv.net/) for automatic environment activation

2. **Setup the development environment**:
   ```bash
   # Clone the repository
   git clone https://github.com/yourusername/sketchup-mcp.git
   cd sketchup-mcp
   
   # Enter the Nix development environment
   nix develop
   
   # Or if you use direnv:
   echo "use flake" > .envrc
   direnv allow
   ```

3. **Build the SketchUp extension**:
   ```bash
   build-extension
   ```
   This will create `su_mcp_v1.6.0.rbz` in the `su_mcp` directory.

4. **Setup Python environment**:
   ```bash
   uv venv .venv
   source .venv/bin/activate
   uv pip install -e .
   ```

### Manual Setup (Alternative)

If you prefer not to use Nix:

1. **Prerequisites**:
   - Ruby with the `rubyzip` gem (`gem install rubyzip`)
   - Python 3.10+
   - [UV](https://github.com/astral-sh/uv) package manager (`brew install uv` on macOS)

2. **Build the SketchUp extension**:
   ```bash
   cd su_mcp
   ruby package.rb
   ```
   This will create `su_mcp_v1.6.0.rbz` in the `su_mcp` directory.

3. **Setup Python environment**:
   ```bash
   uv venv .venv
   source .venv/bin/activate
   uv pip install -e .
   ```

### Installing the SketchUp Extension

1. Open SketchUp
2. Go to Window > Extension Manager
3. Click "Install Extension" 
4. Select the `.rbz` file you built earlier
5. Restart SketchUp

## Usage

### Starting the Connection

1. In SketchUp, go to Extensions > SketchupMCP > Start Server
2. The server will start on the default port (9876)
3. Run the MCP server in your terminal:
   ```bash
   # Make sure you're in the virtual environment
   source .venv/bin/activate
   
   # Run the MCP server
   sketchup-mcp
   ```

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

Alternatively, to use your local installation:

```json
"mcpServers": {
    "sketchup": {
        "command": "path/to/your/venv/bin/python",
        "args": [
            "-m", "sketchup_mcp.server"
        ]
    }
}
```

### Using with Cursor

To use SketchupMCP with Cursor:

1. Install the package globally with UV:
   ```bash
   uvx install sketchup-mcp
   ```

2. Update your Cursor MCP configuration file located at `~/.cursor/mcp.json`:
   ```json
   {
     "mcpServers": {
       "sketchup": {
         "command": "uvx",
         "args": [
           "sketchup-mcp"
         ]
       }
     }
   }
   ```

   If you already have other MCP servers configured, add the sketchup configuration alongside them:
   ```json
   {
     "mcpServers": {
       "other-server": { /* existing configuration */ },
       "sketchup": {
         "command": "uvx",
         "args": [
           "sketchup-mcp"
         ]
       }
     }
   }
   ```

3. Start the SketchUp server:
   - Open SketchUp
   - Go to Extensions > SketchupMCP > Start Server
   
4. Now you can use SketchupMCP with Claude in Cursor! The integration will be available when:
   - SketchUp is running with the server extension started
   - You use Claude within Cursor

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
* **Extension building errors**: Ensure Ruby and the `rubyzip` gem are properly installed
* **Python environment errors**: Make sure you're using Python 3.10+ and have activated the virtual environment
* **Cursor integration issues**: Verify your `~/.cursor/mcp.json` file has the correct configuration

## Technical Details

### Communication Protocol

The system uses a simple JSON-based protocol over TCP sockets:

* **Commands** are sent as JSON objects with a `type` and optional `params`
* **Responses** are JSON objects with a `status` and `result` or `message`

## Development

### Project Structure

- `su_mcp/` - Contains the SketchUp extension files
  - `su_mcp.rb` - Main extension file
  - `package.rb` - Script to build the .rbz extension file
- `src/sketchup_mcp/` - Python MCP server implementation
  - `server.py` - Main server implementation
- `flake.nix` - Nix development environment configuration

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT 