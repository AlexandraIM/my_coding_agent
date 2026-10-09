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

- `ReadFile`: Reads the content of a specific file.
- `WriteFile`: Creates or completely overwrites a file.
- `ApplyPatch`: Performs precise search-and-replace operations within a file.
- `SystemExec`: Executes terminal commands (e.g., running tests, building projects).
- `DelegateTask`: Spawns autonomous sub-agents to handle isolated sub-tasks.
- `MCP Tools`: Dynamically loaded tools provided by connected MCP servers.

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
