# Ella — UX Improvement Plans

> These plans focus entirely on **user experience**: what the user sees, types, reads, and feels while using Ella.
> None require new external dependencies unless noted.

---

## UX-1 — Input History (Up/Down Arrow Navigation)

**Problem:** Every time you retype a prompt you've used before, there is no way to recall it. The input field ignores `↑` / `↓` keys entirely.

**Where it hurts:** Both TUI (`lib/ella/tui.ex`) and CLI (`lib/ella.ex` `loop/2`).

### Plan

#### TUI changes (`lib/ella/tui.ex`)
1. Add `history: []` and `history_cursor: nil` to the initial state in `init/1`.
2. On `{:submit, text}` with a non-empty, non-slash `text`: prepend to `state.history`; keep last 100 entries; reset `history_cursor` to `nil`.
3. Add two new `event_to_msg` clauses for `:up` / `:down` keys → `:history_prev` / `:history_next` messages.
4. Add `update/2` handlers that walk the history list and populate `state.input`.

#### CLI changes (`lib/ella.ex`)
- Delegate to `Owl.IO.input/1` which already supports readline history on most systems.
- If not, maintain a list in the `loop/2` accumulator and manage history state manually.

### Acceptance Criteria
- `↑` in TUI recalls the previous prompt; `↑` again goes one further back.
- `↓` returns toward the most recent entry; one more `↓` clears to empty.
- History survives mode changes but is not persisted across restarts.

---

## UX-2 — Interrupt a Running Agent (Ctrl+C / Ctrl+X)

**Problem:** Once a prompt is submitted, there is no way to cancel a long-running agent loop. The user must wait for it to finish or kill the process entirely.

**Where it hurts:** `lib/ella/tui.ex` `update({:submit, text}, state)` — the `Task.start` runs until the agent finishes.

### Plan

1. Store the task reference in state: `%{state | task: task_ref, busy: true}`.
2. In `event_to_msg`, add a clause: when `busy: true` and `Ctrl+C` pressed → emit `:cancel` message.
3. Add `update(:cancel, state)`:
   - `Task.shutdown(state.task, :brutal_kill)` — kills the running task.
   - Send a stop signal to `state.agent` via a new `Ella.Agent.interrupt/1` call.
   - Return `%{state | busy: false, task: nil}` with a "Cancelled." line.
4. In `Ella.Agent.run_loop/4`, check `state.interrupted` flag at the start of each iteration and return early if set.

### Acceptance Criteria
- `Ctrl+C` while the agent is thinking immediately stops it and shows "Cancelled."
- Subsequent prompts work normally.

---

## UX-3 — Persist Session History Across Restarts

**Problem:** Every time Ella starts, the conversation begins from scratch. Users lose context from their last session.

**Where it hurts:** `lib/ella/storage.ex` already has `save_session/2` / `load_session/2`, but they are only called manually.

### Plan

1. **Auto-save on exit:** In both CLI `loop/2` and TUI `update(:quit, state)`, call `Ella.Agent.save_session(pid, "last")` before shutting down.
2. **Auto-load on start:** After building initial agent state, check for a `"last"` session file. If found and less than 24 hours old, offer to restore:
   - **CLI:** Print `"Resume last session? [y/N]"` → load on `y`.
   - **TUI:** Show a one-time restore banner with `[r] Restore / [n] New session` key handlers.
3. Guard: skip restore prompt if no previous session exists or it is older than 24 hours.

### Acceptance Criteria
- Starting Ella after a previous session asks the user to restore.
- Saying yes loads the previous message history.
- Saying no (or doing nothing) starts fresh.

---

## UX-4 — Richer `/help` Output

**Problem:** `/help` prints one dense line of commands with no descriptions. New users cannot discover what each command does.

**Where it hurts:** `handle_slash("/help", state)` in `lib/ella/tui.ex` and `print_help/0` in `lib/ella.ex`.

### Plan

Replace the single-line dump with a formatted table grouped by section:

```
━━━ Ella Commands ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Modes
  /plan      Read-only analysis. No file writes or shell commands.
  /build     Full access: file edits, shell, all tools.
  /review    Read-only + shell commands (no file writes).

Provider
  /provider              Show current provider and model.
  /provider list         List all configured providers.
  /provider <name>       Switch provider (e.g. /provider ollama).
  /provider models       List models for the current provider.

Session
  /save [name]           Save conversation (default: "default").
  /load [name]           Load a saved conversation.
  /sessions              List saved conversations.
  /rewind                Undo the last exchange.

Info
  /usage      Token usage and cost for this session.
  /context    Message count and context window fill.
  /skills     List available project skills.
  /protected  List write-protected paths.
  /limits     Show iteration/token limits.

Other
  /mcp list           List connected MCP servers.
  /mcp <exec> [args]  Register a new MCP server.
  /init               Create a starter .ella/config.json.
  /exit               Quit Ella.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### Implementation
- Define the table as a list of `{section, [{command, description}]}` tuples in a module attribute.
- Render with `Ella.Output.puts/1` in a loop; section headers get a cyan tag in TUI.

### Acceptance Criteria
- `/help` renders all commands with descriptions and sections.
- Output fits within 80 columns.

---

## UX-5 — Visible Token / Cost Counter in Status Bar

**Problem:** Users have no live awareness of how much context they've consumed or what the session is costing. They find out only after typing `/usage`.

**Where it hurts:** `lib/ella/tui.ex` `view/1` — the status line only shows mode, provider, and model.

### Plan

1. Add `usage: Ella.Llm.Usage.empty()` to TUI state in `init/1`.
2. After each `{:agent_result, _}`, read latest usage from agent and update `state.usage`.
3. Update the status bar in `view/1`:
   ```
    PLAN | openai:gpt-4o | ~4 320 / 120 000 tok | $0.0023
   ```
4. If `usage.cost` is `nil`, omit the cost part.
5. In CLI mode, print usage summary after each reply (the return value of `Ella.Agent.ask/2` already includes `usage`).

### Acceptance Criteria
- Status bar updates after each agent response.
- Token count and cost are always visible without typing `/usage`.
- Bar still fits in 80 columns on a narrow terminal (truncate if needed).

---

## UX-6 — Scrollable Output with Page Up/Down

**Problem:** `Ctrl+Up` / `Ctrl+Down` scroll one line at a time. For long responses, reaching the top takes dozens of key presses.

**Where it hurts:** `lib/ella/tui.ex` `update(:scroll_up/down, state)`.

### Plan

1. Add `PgUp` / `PgDn` event handlers that scroll by `body_height - 2` lines.
2. Add `Home` / `End` to jump to top / bottom.
3. Add mouse-wheel support if `TermUI` exposes `%Event.Mouse{button: :scroll_up/down}`.
4. Show a subtle scroll indicator in the status bar: `[↑ 12 lines]` when scrolled away from bottom.

### Acceptance Criteria
- `PgUp` / `PgDn` scroll by a full page.
- `Home` / `End` jump to top and bottom.
- A scroll indicator shows how far back the user has scrolled.

---

## UX-7 — Inline Diff Preview in CLI Mode

**Problem:** In TUI mode, `Ella.Output.diff/3` shows a beautiful DiffViewer overlay. In CLI/stdio mode, diffs are silently discarded. Users have no idea what changed.

**Where it hurts:** `lib/ella/output.ex` `diff/3`, the `_ ->` branch (line 66) returns `:ok` with no output.

### Plan

1. Implement a simple unified diff printer for stdio using `List.myers_difference/2` (built into Elixir's standard library — no new deps):
   ```elixir
   defp print_diff_stdio(path, before, after_text) do
     puts(tag("--- #{path} (before)", :red))
     puts(tag("+++ #{path} (after)",  :green))

     String.split(before, "\n")
     |> List.myers_difference(String.split(after_text, "\n"))
     |> Enum.each(fn
       {:eq,  lines} -> Enum.each(lines, &puts("  " <> &1))
       {:del, lines} -> Enum.each(lines, &puts(tag("- " <> &1, :red)))
       {:ins, lines} -> Enum.each(lines, &puts(tag("+ " <> &1, :green)))
     end)
   end
   ```
2. Call `print_diff_stdio/3` in the `_ ->` branch of `diff/3`.
3. Gate on `diff_preview: true` in `.ella/config.json` (default `true`) so users can opt out.

### Acceptance Criteria
- Running `ella` (CLI mode) shows a coloured `+/-` diff for every file the agent patches.
- Diff is omitted when `diff_preview: false` in config.
- No external diff tool required.

---

## UX-8 — `/rewind` Command (Undo Last Exchange)

**Problem:** If the agent does something wrong, the user has to manually describe what to fix. There is no built-in undo for the conversation.

**Where it hurts:** `lib/ella.ex` `loop/2` and `lib/ella/tui.ex` — both discard old `messages` after each turn.

### Plan

1. In `Ella.Agent`, track `state.prev_messages` — a snapshot taken at the start of each `handle_call({:ask, …})`.
2. Add `Ella.Agent.rewind/1` GenServer call that swaps `state.messages` back to `state.prev_messages`.
3. In CLI `/rewind` handler and TUI `handle_slash("/rewind", state)`: call `rewind/1` and display "Last exchange undone." or the error.
4. A second `/rewind` without a new prompt says "Nothing to rewind."

### Acceptance Criteria
- `/rewind` after a bad response removes the last user+assistant exchange from the agent's history.
- A second consecutive `/rewind` says "Nothing to rewind."
- File changes are NOT automatically reverted (use existing `/restore` via Snapshot for that).

---

## UX-9 — Startup Welcome Screen with Project Summary

**Problem:** When Ella starts, it prints a greeting and a wall of commands with no immediate sense of what project is loaded, what skills are available, or how much context budget is available.

**Where it hurts:** `lib/ella.ex` `start_cli/0` and `lib/ella/tui.ex` `init/1`.

### Plan

Print a structured welcome block on startup:

```
╭─ Ella ───────────────────────────────────────────────────────────╮
│  Project:   my_coding_agent          Mode: PLAN                  │
│  Provider:  openai › gpt-4o                                      │
│  Skills:    verify, git, review, plan                            │
│  Protected: mix.exs, mix.lock, .github/                         │
│  Context:   0 / 120 000 tokens                                   │
╰──────────────────────────────────────────────── /help for commands ─╯
```

#### Implementation
1. Gather data: sandbox root → project name, provider info, skills list, protected paths, context budget.
2. Format as a Unicode box (box-drawing chars: `╭─╮│╰╯`).
3. In TUI: pre-populate `state.output` with these lines instead of the single `"Ella TUI ready."` string.
4. In CLI: print it at the top of `start_cli/0`.

### Acceptance Criteria
- Welcome block shown exactly once on startup.
- All fields populated; missing values show `"unknown"` / `"none"`.
- Block fits within 80 columns.

---

## UX-10 — `/init` Generates a Commented Config Template

**Problem:** `.ella/config.json` is powerful but undiscoverable. The existing `/init` handler creates a minimal file without explanations.

**Where it hurts:** `/init` handler in `lib/ella.ex`.

### Plan

1. Define a well-commented template (using a `_comment_*` key convention, since JSON has no comments):
   ```json
   {
     "_comment_protected_paths": "Files/dirs the agent will ask permission before modifying.",
     "protected_paths": ["mix.exs", "mix.lock", ".github/"],

     "_comment_disallowed_patterns": "Regex patterns that block shell commands entirely.",
     "disallowed_patterns": [],

     "_comment_require_approval": "If true, ask [y/N] before touching protected files.",
     "require_approval": true,

     "_comment_max_iterations": "Max tool-call loops per user prompt (default 50).",
     "max_iterations": 50,

     "_comment_context_budget": "Max tokens to keep in history before compacting.",
     "context_budget": 120000,

     "_comment_diff_preview": "Show coloured diffs in CLI mode after file edits.",
     "diff_preview": true
   }
   ```
2. Write to `.ella/config.json` only if it does not already exist.
3. Print path of the created file and: "Edit .ella/config.json to customise Ella for this project."

### Acceptance Criteria
- `/init` creates `.ella/config.json` with every key documented.
- Running `/init` twice does not overwrite an existing config.
- Generated file passes `Jason.decode/1` without error.

---

## Summary Table

| # | Improvement | Effort | Impact |
|---|-------------|--------|--------|
| UX-1 | Input history (↑/↓) | Low | High |
| UX-2 | Cancel running agent (Ctrl+C) | Medium | High |
| UX-3 | Persist session across restarts | Medium | High |
| UX-4 | Richer `/help` output | Low | Medium |
| UX-5 | Live token/cost counter in status bar | Low | Medium |
| UX-6 | Page scroll (PgUp/PgDn) | Low | Medium |
| UX-7 | Inline diff preview in CLI mode | Low | High |
| UX-8 | `/rewind` undo last exchange | Medium | High |
| UX-9 | Startup welcome screen | Low | Medium |
| UX-10 | `/init` generates commented config | Low | Medium |
