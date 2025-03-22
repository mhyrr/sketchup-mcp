{
  description = "SketchupMCP - Sketchup Model Context Protocol Integration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        # Ruby with zip gem for packaging the SketchUp extension
        rubyWithDeps = pkgs.ruby.withPackages (ps: with ps; [
          rubyzip
        ]);
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # For building the SketchUp extension
            rubyWithDeps
            
            # For the Python MCP server (keep Python dependencies in venv)
            pkgs.python310
            pkgs.uv
            
            # Useful development tools
            pkgs.git
          ];

          shellHook = ''
            echo "SketchupMCP Development Environment"
            echo ""
            echo "Available commands:"
            echo "  build-extension  - Build the SketchUp extension (.rbz file)"
            echo ""
            echo "Note: Python dependencies are managed through venv"
            echo "  uv venv .venv         - Create virtual environment"
            echo "  source .venv/bin/activate  - Activate virtual environment"
            echo "  uv pip install -e .   - Install project in development mode"
            echo ""

            # Add helper functions
            function build-extension {
              echo "Building SketchUp extension..."
              (cd $PWD/su_mcp && ruby package.rb)
              echo "Done!"
            }
          '';
        };
      }
    );
} 