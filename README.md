# Sketchup MCP

Model Context Protocol integration for Sketchup, allowing Claude to control Sketchup through a TCP socket connection.

## Installation

```bash
pip install sketchup-mcp
```

## Usage

1. Install and run the Sketchup extension (which provides the TCP server)
2. Configure Claude to use the MCP server:

```json
{
    "name": "sketchup",
    "description": "Sketchup integration through Model Context Protocol",
    "package": "sketchup-mcp",
    "module": "sketchup_mcp.server",
    "object": "mcp"
}
```

## Features

- Create, delete, and transform components
- Get selected components
- Set materials
- Export scenes

## License

MIT 