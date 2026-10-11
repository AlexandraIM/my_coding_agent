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
- `delegate_task`: Spawns autonomous sub-agents to handle isolated sub-tasks (research, fixing, testing). This allows the primary agent to maintain focus while complex components are handled in parallel or in isolation.

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

### Writing your own

A skill is the place to put what the agent cannot infer from the code: how to
verify a change, which style to follow, which commands are safe. This repository
uses `.ella/skills/verify.md`:

```markdown
---
name: Verify changes
description: How to check your work after editing code
tools: [system_exec, read_file]
---
After changing any file under `src/`, run:

    npm test

A failing test is a real problem: fix the cause, do not weaken the assertion.
```

The same file works in any language — the agent reads it rather than hardcoding
`mix test`. Swap in `pytest`, `cargo test`, `go test ./...`, or whatever your
project actually runs.

For a pure Elixir setup, this is what `/rewind`, `/protected` and the rest of
this README describe. To inspect what a skill would look like, drop a file in
and run `/skills`.

**Tool restrictions.** `tools:` limits what the agent can use while the skill is
active. The restriction applies to the current request and lifts on the next one,
so it cannot leak into unrelated work. `/skills` lists what was found.

### Safety

All file access is managed by a **Sandbox** (`Ella.Sandbox`). This ensures that the agent cannot escape the project root:
- Absolute paths are rejected.
- Path traversal via `..` is blocked.
- Symbolic links pointing outside the project root are detected and rejected.

Commands that would destroy state irreversibly (`rm`, `sudo`, `git reset --hard`, ...) are blocked and must be run by the user directly.

**Undo.** Ella uses a **Snapshot** mechanism (`Ella.Snapshot`) rather than relying on git. Before a file is modified for the first time in a session, a backup is created. When you run `/rewind`:
- Modified files are restored to their original state.
- Files created by the agent during the session are deleted.

This ensures a precise rollback without touching your uncommitted work or requiring a git repository.

## Quick Start Guide

### Running from source

```sh
iex -S mix
```

then:

```elixir
Ella.start_cli()
```

### Building a single-file CLI

```sh
mix escript.build   # produces ./ella
./ella
```

One self-contained executable (~2 MB) with the application and all
dependencies inside. **Erlang/OTP must be installed on the user's machine** —
see [Standalone binaries](#standalone-binaries) if that is not acceptable.

The CLI is interactive, so it needs a real terminal. It will not work when
piped into `head` or run from a script without a TTY.

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
| `/rewind` | Undo everything the agent changed this session |
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
3. **Build**: Switch to `/build` mode. The agent implements the changes. For complex tasks, it may delegate specific sub-problems to autonomous sub-agents to maintain efficiency.
4. **Verify**: The agent uses `system_exec` to run tests and verify that the implementation is correct.

## Customization

You can define custom coding standards, architectural preferences, or project-specific constraints by modifying the `ProjectRules` configuration. The agent references these rules to ensure consistency across the codebase.

## Standalone binaries

`mix escript.build` still requires Erlang on the user's machine. If Ella has to
reach people who do not have it, the options are:

| Approach | Needs Erlang on user's machine | Self-contained |
| :--- | :--- | :--- |
| `mix escript.build` (current) | yes | no |
| `mix release` + tar.gz | yes | no |
| [Burrito](https://github.com/burrito-elixir/burrito) | no | yes |

**Burrito is the intended path** for a single binary that runs anywhere. It is
not configured yet, deliberately, for two reasons:

1. **Toolchain.** It pins **Zig 0.15.2**. The README warns that newer Zig is
   unsupported. Verify the build works before investing in the config.
2. **Entry point.** Burrito starts the application through a `:mod` callback,
   so `mix.exs` would need an `Ella.Application` whose `start/2` calls
   `Ella.start_cli()`.

`bakeware` is not an alternative: it was last updated in May 2022, and Burrito
is the maintained successor.

To set it up: add `{:burrito, "~> 1.6", runtime: false}`, add the `:mod` entry
point, configure `releases/0` with `steps: [:assemble, &Burrito.wrap/1]`, then
run `MIX_ENV=prod mix release`.
