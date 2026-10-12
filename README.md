# Ella

Ella is an AI-powered coding assistant built in Elixir. It utilizes an agentic loop to interact directly with a codebase, allowing it to understand context, design solutions, and implement changes autonomously.

## Key Features

For a detailed visual overview of how the system is structured, see [ella_architecture.html](./ella_architecture.html).

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

## Session limits

The same `.ella/config.json` sets the boundaries of a session. These are project properties, not
agent internals, so each repository can pick its own trade-off between cost and patience:

```json
{
  "max_attempts": 4,
  "request_timeout_ms": 120000,
  "context_budget": 120000,
  "max_iterations": 30
}
```

| Key | Meaning | Default |
| :--- | :--- | :--- |
| `max_attempts` | Total attempts per LLM call, including the first | `4` |
| `request_timeout_ms` | How long to wait for the provider before giving up | `120000` |
| `context_budget` | Token budget for conversation history before compaction kicks in | `120000` |
| `max_iterations` | Agent steps (tool calls) allowed per user request | `30` |

Non-integer or non-positive values are ignored and the default is used instead — a typo in the
config should not leave the agent without limits.

Non-integer or non-positive values are ignored and the default is used instead — a typo in the
config should not leave the agent without limits.

## System prompt

The system prompt is assembled by `lib/ella/prompt.ex` from four sections, each specific to the
active mode, followed by the project rules and the skill catalog:

1. **Role** — what the mode is for and its hard rules.
2. **Tools** — when to reach for each one. Tool *schemas* only describe argument shapes; this is
   where the agent learns that `apply_patch` knows the SEARCH/REPLACE format, that a first-class
   edit is safer than a rewrite, and that every change is backed up so `/rewind` exists.
3. **Working process** — minimal edits, verify before claiming, and the rule that a test only counts
   if it was actually run and seen to pass.
4. **Output format** — what to report and what to leave out (never the diff, which the user already
   has).

Keeping the prompt in its own module means it can be read and tested without starting the agent —
`test/ella/prompt_test.exs` asserts both modes mention their sections and that plan mode offers no
file-modification tools at all.

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
verify a change, which style to follow, which commands are safe. For an Elixir project, you might use `.ella/skills/verify.md`:

```markdown
---
name: Verify changes
description: How to check your work after editing code
tools: [system_exec, read_file]
---
After changing any file under `lib/`, run:

    mix test

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

## Prerequisites

| Requirement | Minimum | Why |
|---|---|---|
| **Erlang/OTP** | 26+ (29+ recommended) | Runtime for the escript binary |
| **Elixir** | 1.20+ | Build tool (`mix`) and source compilation |
| **Zig** | 0.16.0 | Only to build the standalone binary |
| **xz** | any | Only to build the standalone binary |
| **Git** | any | Snapshot backups and project detection |
| **ripgrep** (optional) | any | Speeds up `grep` tool — falls back to built-in walker if missing |

### OS-Specific Setup

**macOS (Homebrew)**
```sh
brew install elixir ripgrep
```

**Linux (apt)**
```sh
sudo apt update && sudo apt install -y curl gnupg
curl -fsSL https://packages.elixir-lang.org/elastic/elixir/elixir.gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/elixir-archive-keyring.gpg
echo "deb https://packages.elixir-lang.org/elastic/elixir ubuntu-main stable" | sudo tee /etc/apt/sources.list.d/elixir.list
sudo apt update && sudo apt install -y elixir ripgrep
```

**Windows (Scoop)**
```powershell
scoop install elixir ripgrep
```

> **Tip:** On all platforms, `kiex` or `asdf` can pin exact Elixir/OTP versions per-project.

## Getting Started


Depending on your goals, choose one of the following ways to run Ella.

### 🚀 Quick Start (Developer Mode)
The fastest way to start interacting with the agent without building any binaries:

```sh
# 1. Install dependencies
mix deps.get

# 2. Start the interactive shell
iex -S mix
```

Then, inside the Elixir shell, run:
```elixir
Ella.start_cli()
```

### 🛠️ Build a Local CLI
If you want a convenient command-line tool that requires Erlang to be installed on your machine:

```sh
mix escript.build   # produces ./ella
./ella
```

### 📦 Build a Standalone Binary (No Erlang needed)
To create a self-contained executable that you can share with others (bundles the BEAM runtime):

```sh
# Requires Zig and xz (see Installation)
MIX_ENV=prod mix release     # produces ./burrito_out/ella_native
```
See [Standalone binaries](#standalone-binaries) for more details.

---

## Configuration (API Keys)

Ella requires an LLM provider. Set the environment variable for your chosen provider before starting:

**OpenAI** (default):
```sh
export OPENAI_API_KEY="sk-..."
```

**Poolside:**
```sh
export LLM_PROVIDER=poolside
export POOLSIDE_API_KEY="..."
```

**Mistral:**
```sh
export LLM_PROVIDER=mistral
export MISTRAL_API_KEY="..."
```

**Ollama** (local):
```sh
export LLM_PROVIDER=ollama
export LLM_MODEL="gemma4:31b-cloud"  # optional
```

**OpenCode-compatible** (local):
```sh
export LLM_PROVIDER=opencode
export OPENCODE_API_KEY="..."        # optional
export OPENCODE_BASE_URL="http://localhost:4096/v1"  # optional
```

The model defaults to `gpt-4o` (OpenAI), `poolside-code` (Poolside), `codestral-latest` (Mistral), `gemma4:31b-cloud` (Ollama). Override with `LLM_MODEL`.

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
| `/limits` | Show the active session limits (attempts, timeout, budget, iterations) |
| `/rewind` | Undo everything the agent changed this session |
| `/mcp [executable args]` | Register an MCP server (or show help if called without args) |
| `/exit` | Terminate the session |

### Reliability

Responses stream token by token via SSE, so the agent's reply appears while it is still being
generated. Streaming is transparent: the assembled message and token usage are identical to a
non-streamed call, and an adapter without `chat_completion_stream/4` falls back to a plain
request rather than losing its reply.

Transient LLM failures (429, 408, 5xx, network) are retried with exponential backoff and jitter,
up to `max_attempts`, honouring `Retry-After` when the server sends it — in seconds or as an HTTP
date, whichever the provider chose. Permanent failures (401, malformed requests) fail immediately
rather than burning retries.

A stream that ends without its `[DONE]` marker is treated as interrupted rather than complete: SSE
responses carry no length, so a dropped connection is indistinguishable from a finished one if you
only look at the transport. Retrying such a stream is safe **only** before the user has seen any
output — afterwards a retry would print the same reply twice, so the agent reports the error instead
of silently duplicating or truncating its answer.

Conversation history is compacted before each request once it approaches the context budget:
older messages collapse into a summary, and long tool results are truncated. When even that
cannot fit, the agent reports the problem instead of sending a request the API will reject.

Because "four characters per token" is only a rough guess, the agent calibrates its estimate
against the real `prompt_tokens` the provider returns for each request. The ratio is smoothed and
clamped, so a single unusual prompt cannot throw every later estimate off.

### Tool calls

Providers stream a tool call in pieces: the name arrives first, then the arguments as fragments of
JSON. Both adapters accumulate those fragments by their index into a single call, so a tool
invocation split across ten chunks arrives at the agent as one executable call rather than ten
half-built ones. Provider-specific shapes (flat `name`/`arguments`, a missing `id`) are normalised
to the same structure before the agent sees them.

## Typical Workflow

The recommended workflow for using Ella is as follows:

1. **Plan**: Start in `/plan` mode. Describe the feature or bug. The agent analyzes the code and proposes a detailed design.
2. **Approve**: Review the proposed plan. Request adjustments if necessary.
3. **Build**: Switch to `/build` mode. The agent implements the changes. For complex tasks, it may delegate specific sub-problems to autonomous sub-agents to maintain efficiency.
4. **Verify**: The agent uses `system_exec` to run tests and verify that the implementation is correct.

## Customization

You can define custom coding standards, architectural preferences, or project-specific constraints by modifying the `ProjectRules` configuration. The agent references these rules to ensure consistency across the codebase.

## Standalone binaries

`mix escript.build` still requires Erlang on the user's machine. For people who
do not have it, Ella can build a self-contained executable with
[Burrito](https://github.com/burrito-elixir/burrito) — the binary bundles the
BEAM runtime along with the application:

```sh
brew install zig xz           # or: apt install zig xz-utils
mix deps.get
MIX_ENV=prod mix release     # produces ./burrito_out/ella_native
```

| Approach | Needs Erlang on user's machine | Self-contained |
| :--- | :--- | :--- |
| `mix escript.build` | yes | no |
| `mix release` + tar.gz | yes | no |
| `mix release` (Burrito) | no | yes |

### One binary per platform, built on that platform

The release config declares a single target: the platform running the build.
That is not an accident — ERTS is taken from the build machine itself
(`lib/ella/erts_resolver.ex`), because Burrito's CDN has no prebuilt ERTS for
OTP 29.1.1 yet. Shipping the runtime from the host means a cross-build would
embed the wrong architecture, so each platform builds its own binary. In CI
that is simply a matrix of runners; see below.

To get Burrito to download ERTS for foreign targets instead, drop
`extra_steps` from the release config in `mix.exs` and list the targets you
want — possible once the CDN catches up with the OTP release.

### How the packaging works

Burrito needs a `:mod` callback to start from, so `Ella.Application` launches
the CLI when — and only when — the process is running as a standalone binary
(its environment sets `__BURRITO`). Under `mix test` or `iex -S mix` that
variable is absent, so the interactive loop never starts and cannot block the
test run. After the session ends the VM is halted explicitly: nothing else
would ever finish.

The ERTS resolver is registered by a build step
(`lib/ella/build_steps/register_erts_resolver.ex`) rather than from
`Ella.Application` — module bodies only run at compile time, so a resolver
registered there works on the first build after a change and silently
disappears on the next one that has nothing to recompile.

Once unpacked, a binary extracts itself to `~/.burrito/` on first run and
reuses that copy afterwards:

```sh
./burrito_out/ella_native maintenance directory   # where it unpacked itself
./burrito_out/ella_native maintenance uninstall   # remove the unpacked copy
```

`bakeware` is not an alternative: it was last updated in May 2022, and Burrito
is the maintained successor.
