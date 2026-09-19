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

Once connected, Claude can interact with Sketchup using the following capabilities:

#### Tools

* `get_model_info` - Inspect the model: entity counts by type, bounds, scenes, layers, materials, units, selection. Pass an entity id for per-entity details (bounds, volume, surface area, face/edge counts). Read-only
* `create_component` - Create a new component (`cube`, `cylinder`, `sphere` or `cone`) at a position with given dimensions. Use `unit` (`inch` default, `mm`, `cm`, `m`) to control the unit of position/dimensions; the result is a real component instance, not loose geometry
* `delete_component` - Remove a component from the scene by entity ID
* `transform_component` - Move, rotate, or scale a component
* `get_selection` - Get currently selected entities
* `get_addon_status` - Lightweight health check: SketchUp version/platform/Pro status, current model, bridge port and uptime. Verify the extension is reachable before anything else
* `get_viewport_screenshot` - Capture the current 3D viewport and return it as an **image** the agent can see directly (no file reading) — pair with `set_camera` to inspect from specific viewpoints
* `set_camera` - Position the camera by standard view (`top`/`front`/`iso`/...) or explicit eye/target/up, with fov and perspective control; pair with `export_scene` to capture from the new viewpoint
* `set_material` - Apply a material/color to a component (named colors or `#RRGGBB`)
* `boolean_operation` - Solid `union`/`difference`/`intersection` between two groups or component instances, via SketchUp's native solid operations. Operates on copies; `delete_originals` also removes the source entities. Reliable for normal-sized geometry; for very small features in very large models SketchUp's solid ops can misbehave (see the joints below for the robust alternative)
* `create_mortise_tenon` / `create_finger_joint` / `create_dovetail` - Woodworking joints between two boards, cut with classic face-split + pushpull geometry (deterministic, no Pro solid tools, boards keep their entity IDs). All accept a `unit` parameter (`inch` default, `mm`, `cm`, `m`). Boards should be axis-aligned boxes; features must fit within the board face
* `export_scene` - Export the scene to `skp`, `obj`, `dae`, `stl`, `png` or `jpg`. `filepath` sets an absolute destination (parent folders created); without it a timestamped file goes to the system temp directory and the response reports its `path`. Image exports accept `width`/`height`. `skp` exports use `save_copy` so the working model's path stays bound where it was (models never saved before fall back to `save`)
* `set_selection` - Control the selection: replace/add/remove entities by id, or clear
* `undo` / `redo` - Step the model's undo stack
* `lookup_ruby_api` - Look up the official SketchUp Ruby API docs (ruby.sketchup.com) by class and method, so the agent stops guessing signatures
* `eval_ruby` - Execute arbitrary Ruby code in SketchUp for advanced operations (saving, layers, scenes, import, follow-me, shadows, ... — see the tool description for recipes). Each evaluation runs inside an undoable operation; if the code raises, the changes are rolled back. Set `SKETCHUP_MCP_SAFE_MODE=1` in the MCP server environment to screen scripts first: file I/O, process spawning, network access, dynamic eval and SketchUp system actions are blocked with the matching reason so the agent can rewrite (a guardrail, not a sandbox)

#### Asset layer (free CC0 sources, no API keys required unless noted)

* `search_textures` / `apply_texture` - Search [ambientCG](https://ambientcg.com) or [Poly Haven](https://polyhaven.com) CC0 textures and apply them to an entity as a textured material (`repeat` sets the tile size in inches). Downloads are cached in `~/.sketchup_mcp_assets`
* `get_asset_preview` - Fetch a texture thumbnail as an image to see it before applying
* `search_sketchfab` - Public Sketchfab model search; downloads need a Sketchfab account, then `import_glb` accepts any glb URL
* `search_polypizza` - Free low-poly models from [Poly Pizza](https://poly.pizza); set `POLYPIZZA_API_KEY` (free) in the MCP server environment
* `import_glb` / `import_file` - Import from URL or local disk: **SketchUp 2025+ imports GLB natively with embedded textures**; also obj/dae/stl/3ds, dwg/dxf (Pro), ifc, kmz, images, and `.skp` files (use for 3D Warehouse downloads and local component libraries)

#### Known limitations

* `chamfer_edges`/`fillet_edges` were removed: their handlers predated the current bridge and called long-removed APIs (`Entity#copy`), so they never worked. SketchUp has no native edge-rounding API; use `eval_ruby` or an extension like RoundCorner for that
* Right after editing a board, SketchUp may report a sentinel volume (-1) for it until the next full rebuild; `get_model_info` omits volume in that case

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