# CLAUDE.md

Project-specific guidelines for `sketchup-mcp`. Merge with the global
`~/.claude/CLAUDE.md`.

## Handoff location

Save `/handoff` documents to `.claude/memory/` in the project root
(not the OS temp dir). Use timestamp prefix:

```
.claude/memory/YYYYMMDDHHMM-HANDOFF.md
```

`.claude/` is gitignored — these are session-local notes, not source.

## Project conventions

- **Branches:** push feature/fix branches to the `fork` remote
  (`gleydson115-code/sketchup-mcp`), never to `origin`
  (`mhyrr/sketchup-mcp`). Open PRs from `fork` → `origin`.
- **Commits:** conventional commit format, no `Co-Authored-By` line.
  Attribution disabled globally.
- **Ruby changes:** rebuild `.rbz` via PowerShell `Compress-Archive`
  pattern (see plan), not `package.rb` (ruby not on PATH). Output:
  `C:\Users\gleyd\Downloads\sketchup-mcp-extension.rbz`.
- **PRs:** body should be self-contained (problem, root cause, fix,
  diff scope, verification, manual test plan, caveats).
