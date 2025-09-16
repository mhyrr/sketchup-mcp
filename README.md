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

## Installation and Usage

### 1. Setup Python Environment
*   Make sure you have `uv` installed. If not, you can usually install it with `brew install uv` on macOS or `pip install uv` on other systems.
*   Create a virtual environment in the project root:
    ```bash
    uv venv
    ```
*   Install the required Python dependencies:
    ```bash
    uv pip install -r requirements.txt
    ```

### 2. Setup Ruby Environment (for packaging the extension)
*   You'll need Ruby to package the Sketchup extension. On Debian-based systems (like Ubuntu), you can install it with:
    ```bash
    sudo apt-get update
    sudo apt-get install -y ruby-full
    ```
*   You also need the `rubyzip` gem:
    ```bash
    sudo gem install rubyzip
    ```

### 3. Package the Sketchup Extension
*   Run the packaging script from the project root:
    ```bash
    ruby su_mcp/package.rb
    ```
*   This will create a file named `su_mcp_v1.6.0.rbz` in the project's root directory.

### 4. Install and Run
1.  **Install the extension in Sketchup:** Open Sketchup, go to `Window > Extension Manager`, click "Install Extension", and select the `su_mcp_v1.6.0.rbz` file you just created.
2.  **Start the Python MCP server:** In your terminal (from the project root), run:
    ```bash
    uv run sketchup-mcp
    ```
3.  **Start the server in Sketchup:** In Sketchup, go to the menu `Plugins > MCP Server > Start Server`.

The Python server and the Sketchup extension should now be connected and ready to receive commands.

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