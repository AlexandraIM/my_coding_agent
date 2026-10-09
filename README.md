# Ella

Ella is an AI-powered coding assistant built in Elixir. It utilizes an agentic loop to interact directly with a codebase, allowing it to understand context, design solutions, and implement changes autonomously.

## Key Features

The agent operates in two distinct modes to ensure safety and architectural integrity:

- **Plan Mode**: A read-only mode used for exploration, analysis, and architectural design. In this mode, the agent can read files and execute certain commands but cannot modify the codebase.
- **Build Mode**: A full-access mode used for implementation. In this mode, the agent can write files, apply patches, and execute system commands to implement the agreed-upon plan.

## Model Context Protocol (MCP) Integration

Ella fully supports the **Model Context Protocol (MCP)**, enabling it to connect to external MCP servers. This allows the agent to extend its capabilities dynamically by using a wide range of third-party tools and data sources without needing to rewrite its core logic.

## Toolset

Ella is equipped with a powerful set of tools to interact with the environment:

### Navigation (read-only, available in Plan Mode)

- `list_dir`: Lists a directory as a tree with file sizes. Use this first to understand project structure.
- `glob`: Finds files matching a pattern, e.g. `lib/**/*.ex`.
- `grep`: Searches file contents with a regular expression. Returns `file:line` hits. Uses ripgrep when available, otherwise falls back to a built-in walker.
- `read_file`: Reads a file. Supports `offset`/`limit` for reading large files in parts.

### Modification (Build Mode only)

- `write_file`: Creates or completely overwrites a file.
- `apply_patch`: Performs precise search-and-replace operations within a file. Refuses ambiguous search strings.

### Execution (Build Mode only)

- `system_exec`: Executes terminal commands through a shell (pipes, `&&`, redirection supported), with a timeout and output truncation.
- `delegate_task`: Spawns autonomous sub-agents to handle isolated sub-tasks.

### Extensions

- `MCP Tools`: Dynamically loaded tools provided by connected MCP servers. Tools that do not declare `readOnlyHint` are hidden in Plan Mode.

### Safety

All file access is confined to the project root: absolute paths, `..` traversal, and symlinks
pointing outside the project are rejected. Commands that would destroy state irreversibly
(`rm`, `sudo`, `git reset --hard`, ...) are blocked and must be run by the user directly.

## Quick Start Guide

### Starting the CLI
To launch the interactive CLI, run the following command in your IEx shell:

```elixir
Ella.start_cli()
```

### CLI Commands

| Command | Action |
| :--- | :--- |
| `/plan` | Switch to **Plan Mode** (Read-only architectural design) |
| `/build` | Switch to **Build Mode** (Full access for implementation) |
| `/execute` | Immediately switch to **Build Mode** and execute the current goal |
| `exit` | Terminate the session |

## Typical Workflow

The recommended workflow for using Ella is as follows:

1. **Plan**: Start in `/plan` mode. Describe the feature or bug. The agent analyzes the code and proposes a detailed design.
2. **Approve**: Review the proposed plan. Request adjustments if necessary.
3. **Build**: Switch to `/build` mode. The agent implements the changes based on the approved plan.
4. **Verify**: The agent uses `SystemExec` to run tests and verify that the implementation is correct.

## Customization

You can define custom coding standards, architectural preferences, or project-specific constraints by modifying the `ProjectRules` configuration. The agent references these rules to ensure consistency across the codebase.
