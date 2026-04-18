# Changelog

All notable changes to this project will be documented in this file.

## [2.0.0] — 2026-04-18

Major reliability and capability overhaul. **Drop-in upgrade** — existing
tool calls continue to work unchanged; all new features are additive.

### Fixed (reliability)

- **Persistent connections.** Python kept the socket open, Ruby closed
  it after every request. First `sendall` of each subsequent call hit
  `BrokenPipeError` and triggered a reconnect. This mismatch was the
  single largest source of "No data received" and "Communication
  error" reports. Ruby now serves a client socket until EOF.
- **Multi-line JSON payloads.** `client.gets` on the Ruby side read
  only until the first `\n`, which corrupted `eval_ruby` requests that
  included multi-line Ruby code. Replaced with an incremental buffered
  parser on both sides.
- **`FastMCP(description=)` kwarg.** Upstream 0.1.17 passed an
  unsupported keyword that broke with current `mcp` SDK versions
  (`TypeError: FastMCP.__init__() got an unexpected keyword
  argument 'description'`). Renamed to `instructions=`.
- **Silent response truncation.** JSON parse after every 8 KB chunk
  was O(n²) for large responses and could miss complete messages.
  Replaced with length-aware prefix scan.
- **Runaway `eval_ruby` hangs.** Added `Timeout::timeout` guard
  (default 30 s, configurable via `{"timeout": N}` param or
  `SKETCHUP_MCP_EVAL_TIMEOUT`).
- **Stale retry-id collisions.** Python used the same request ID on
  every retry; late responses from the first attempt collided with
  the second. Each attempt now uses a fresh monotonic id and wrong-id
  responses are discarded.
- **Thread safety.** Global Python connection was shared without
  locking. Added `threading.Lock` around send/receive so concurrent
  MCP calls serialize.
- **Actionable "server not running" message.** `ConnectionRefusedError`
  on connect now raises `SketchupServerNotRunningError` with explicit
  recovery steps instead of generic "Communication error".

### Added (capability)

- **`batch` tool.** Execute a list of sub-tool calls in one round
  trip, wrapped in a single `start_operation` / `commit_operation`
  for atomic undo. Dramatically reduces socket overhead for
  multi-step geometry scripts.
- **`undo_last` tool.** Programmatic `model.undo_operation` — the LLM
  can recover from a bad batch without asking the user.
- **`measure` tool.** Structured bounds / position / material query
  by entity ID, with all lengths in centimetres so the client never
  has to guess units.
- **`snapshot` tool.** Sets camera + renders PNG in one call,
  replacing the ad-hoc `eval_ruby` + `write_image` + separate read
  pattern.
- **`list_definitions` tool.** Enumerate all component definitions
  with instance counts and bounds, optionally filtered by regex.
- **`list_instances` tool.** Enumerate instances with optional
  definition-name and bounding-box filters.
- **`select` tool.** Programmatically set `model.selection` by
  entity IDs.
- **`units_info` tool.** Expose model length unit + cm↔inch
  conversion factors.
- **`transaction` tool.** Explicit `start` / `commit` / `abort`
  control for workflows that span multiple MCP calls.
- **`ping` tool.** Cheap health check returning version + timestamp.

### Added (developer experience)

- **Configurable via environment variables:**
  - `SKETCHUP_MCP_HOST` (default `localhost`)
  - `SKETCHUP_MCP_PORT` (default `9876`)
  - `SKETCHUP_MCP_TIMEOUT` (default 60 s — per-request)
  - `SKETCHUP_MCP_LONG_TIMEOUT` (default 300 s — `batch` / `snapshot`)
  - `SKETCHUP_MCP_EVAL_TIMEOUT` (default 30 s — `eval_ruby`)
  - `SKETCHUP_MCP_MAX_RETRIES` (default 2)
  - `SKETCHUP_MCP_READ_CHUNK` (default 32 KB)
  - `SKETCHUP_MCP_LOG_LEVEL` (default `INFO`)
  - `SKETCHUP_MCP_LOG_FILE` (optional absolute path, Ruby side)
  - `SKETCHUP_MCP_VERBOSE_CONSOLE` (set to `1` for Ruby console spam)
- **Leveled logging** in the Ruby plugin (DEBUG / INFO / WARN /
  ERROR). Console stays quiet unless `WARN+` or verbose flag is set.
- **Structured `eval_ruby` results.** Returns
  `{value, inspect, class}` so Hash / Array results survive the wire
  as JSON. Old `result.to_s` behaviour is preserved via `inspect`.
- **Structured JSON-RPC error codes** mapped to typed Python
  exceptions:
  - `-32700` parse error
  - `-32600` invalid request
  - `-32601` method not found
  - `-32602` invalid params
  - `-32603` internal
  - `-32000` transport
  - `-32001` timeout
  - `-32002` Ruby exception (with backtrace in `data.backtrace`)

### Migration from 0.1.x

All existing tool calls (`create_component`, `eval_ruby`, etc.)
continue to work without changes. The `eval_ruby` return shape
changed from a plain string to `{value, inspect, class}`; the
`inspect` field preserves the old string so existing clients can
fall back to it. Requests can still be sent as newline-delimited
JSON — the new server also accepts concatenated objects.

Existing `claude_desktop_config.json` entries (`"command": "uvx",
"args": ["sketchup-mcp"]`) pick up the new package automatically
once PyPI is refreshed. For local development, point `uv` at the
repo root: `"command": "uv", "args": ["run", "--directory",
"/path/to/sketchup-mcp", "python", "-m", "sketchup_mcp"]`.

### Packaging

- `su_mcp/extension.json` version → `2.0.0`
- `pyproject.toml` version → `2.0.0`
- New: `scripts/smoke_test.py` — 15 assertions covering the failure
  modes above.
- New: `CHANGELOG.md` (this file).
