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
- `load_skill`: Reads the full text of a project skill (see below).

## Protected files

Some files break the whole project when edited carelessly — build files, lockfiles, CI config.
List them in `.ella/config.json` and the agent asks before touching them:

```json
{
  "protected_paths": ["mix.exs", "mix.lock", ".formatter.exs", ".github/"],
  "require_approval": true
}
```

A rule ending in `/` covers everything inside that directory. `/protected` shows the active list.

**In a non-interactive session (CI, pipes) no question is asked and the change is refused.**
A prompt nobody can answer would hang the run, so the agent is told to ask you instead.
Set `require_approval` to `false` to allow the change with a warning printed instead.

## Skills

Skills are Markdown files with YAML-style frontmatter that add project-specific
instructions — how tests are run, which style to follow, which commands are safe.
They live in `.ella/skills/` (committed with the repository) or `~/.ella/skills/`
(personal). A project skill with the same name overrides a personal one.

```markdown
---
name: Running tests
description: How to run the test suite in this project
tools: [read_file, system_exec]   # optional: restricts the agent
---
Run the full suite with `mix test`. Always run it after changing code in `lib/`.
```

Only `description` is required. `name` defaults to the file name.

**Progressive disclosure.** Just the name and description go into the system
prompt; the body is loaded on demand via `load_skill`. Keeping every skill in the
prompt permanently would cost as much context as the instructions themselves.

**Tool restrictions.** `tools:` limits what the agent can use while the skill is
active. The restriction applies to the current request and lifts on the next one,
so it cannot leak into unrelated work. `/skills` lists what was found.

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
| `/usage` | Show tokens and cost consumed this session |
| `/context` | Show current context size against the budget |
| `/skills` | List discovered project skills |
| `/protected` | Show protected paths and whether approval is required |
| `/mcp <executable> <args>` | Register an MCP server |
| `/exit` | Terminate the session |

### Reliability

Responses stream token by token via SSE, so the agent's reply appears while it is still being
generated. Streaming is transparent: the assembled message and token usage are identical to a
non-streamed call, and an adapter without `chat_completion_stream/4` falls back to a plain
request rather than losing its reply.

Transient LLM failures (429, 5xx, network) are retried with exponential backoff and jitter,
up to four attempts, honouring `Retry-After` when the server sends it. Permanent failures
(401, malformed requests) fail immediately rather than burning retries.

Conversation history is compacted before each request once it approaches the context budget:
older messages collapse into a summary, and long tool results are truncated. When even that
cannot fit, the agent reports the problem instead of sending a request the API will reject.

## Typical Workflow

The recommended workflow for using Ella is as follows:

1. **Plan**: Start in `/plan` mode. Describe the feature or bug. The agent analyzes the code and proposes a detailed design.
2. **Approve**: Review the proposed plan. Request adjustments if necessary.
3. **Build**: Switch to `/build` mode. The agent implements the changes based on the approved plan.
4. **Verify**: The agent uses `SystemExec` to run tests and verify that the implementation is correct.

## Customization

You can define custom coding standards, architectural preferences, or project-specific constraints by modifying the `ProjectRules` configuration. The agent references these rules to ensure consistency across the codebase.
