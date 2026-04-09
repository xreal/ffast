# ffast

Fast code intelligence for AI agents, built with Zig.

`ffast` is a local-first MCP server, built with Zig for blazing-fast performance. It helps coding agents understand repositories in less time and with fewer tokens by returning structured answers instead of noisy raw output.

## Why ffast

- Better repo understanding in less time and with fewer tokens
- Faster repo navigation for agents and humans
- Built with Zig for a small, fast native binary
- Structured tools for tree, search, symbols, and changes
- Built-in dependency graph for impact analysis
- Privacy-first defaults: local processing, no telemetry

## Features

- MCP-native server over stdio
- Compact project tree with filtering and sorting
- File symbol outlines with line locations
- Fast text search with optional regex
- Dependency graph (forward and reverse dependencies)
- Snapshot metadata and incremental change tracking
- Indexer status and explicit index refresh

## Install

```bash
curl -fsSL https://github.com/xreal/ffast/releases/latest/download/install.sh | sh
```

This installs the correct binary for your platform and registers `ffast` as an MCP server.

## Quick start

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/ffast mcp
```

Example MCP config:

```json
{
  "mcpServers": {
    "ffast": {
      "command": "/absolute/path/to/ffast/zig-out/bin/ffast",
      "args": ["mcp"],
      "cwd": "/absolute/path/to/your-project"
    }
  }
}
```

## MCP tools

| Tool | Purpose |
| --- | --- |
| `ffast_tree` | Project file tree (compact nested arrays) |
| `ffast_outline` | Symbol outline for one file |
| `ffast_search` | Text search across the codebase |
| `ffast_deps` | Dependency graph (imports + reverse imports) |
| `ffast_index` | Refresh the index |
| `ffast_status` | Indexer and runtime status |
| `ffast_snapshot` | Read/write snapshot metadata |
| `ffast_changes` | Files changed since sequence number |

## Privacy

- No telemetry
- No outbound network calls
