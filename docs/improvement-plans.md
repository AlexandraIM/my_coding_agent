# Ella — Detailed Improvement Plans

> Each item is self-contained and can be executed independently. Items are ordered by priority.

---

## Plan 1 — Test `apply_patch` (High Priority)

**Goal:** Achieve full branch coverage of `Ella.Tools.ApplyPatch` — the most complex module with zero tests.

**File to create:** `test/ella/tools/apply_patch_test.exs`

### Background
`ApplyPatch` has three matching strategies applied in order:
1. Exact match (after NBSP normalisation)
2. Whitespace-normalised match (trim trailing, collapse blank lines)
3. Fuzzy/relative-indent match (strip leading whitespace per line)

It also supports multi-block `<<<< SEARCH / ==== / >>>>` format.

### Steps

#### Step 1 — Scaffold test module
```elixir
defmodule Ella.Tools.ApplyPatchTest do
  use ExUnit.Case, async: true

  alias Ella.Tools.ApplyPatch

  setup do
    root = System.tmp_dir!() |> Path.join("apply_patch_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(root)
    Application.put_env(:ella, :sandbox_root, root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
```

#### Step 2 — Exact-match tests
- **Happy path:** search string found exactly once → file is updated, `{:ok, "Successfully patched …"}` returned.
- **Ambiguous match:** search string found 2+ times → `{:error, "Ambiguous patch …"}`.
- **Not found:** search string absent → falls through to fuzzy → returns `{:error, "Could not find …"}`.
- **NBSP normalisation:** replace `\u00A0` in both file content and search string; exact match should still work.

#### Step 3 — Whitespace-normalisation strategy tests
- File has trailing spaces on some lines; search string does not → strategy 2 matches.
- File has 3+ consecutive blank lines; search has 1 → strategy 2 matches after blank-line collapse.

#### Step 4 — Relative-indent strategy tests
- File indents a function body by 4 spaces; search string uses no indentation → strategy 3 matches and the replacement inherits the original indent.
- Multiple occurrences after stripping → strategy 3 returns `:error` (not `{:ok, …}`).

#### Step 5 — Multi-block `<<<< SEARCH` format tests
- Two consecutive blocks, both found exactly → both applied in order, file updated once.
- First block found, second not found → `{:error, "Could not find one of the search blocks …"}`.
- `search` param contains the block markers but no actual blocks (malformed) → `{:error, "No SEARCH/REPLACE blocks found …"}`.
- Block with CRLF line endings (`\r\n`) → still matches after normalisation.

#### Step 6 — `WriteGuard` / sandbox rejection tests
- Path outside sandbox root → `{:error, _}` returned without writing.
- Missing `path`/`search`/`replace` keys → `{:error, "Invalid arguments …"}`.

#### Step 7 — Run and verify
```bash
mix test test/ella/tools/apply_patch_test.exs --trace
```

### Acceptance Criteria
- All strategy branches covered (exact, whitespace, relative-indent).
- Multi-block happy path and partial-failure path covered.
- Zero new files created outside the temp sandbox.

---

## Plan 2 — Test file tools (`write_file`, `read_file`, `approve`) (High Priority)

**Goal:** Add isolated unit tests for the remaining untested tool modules.

### Part A — `write_file`

**File to create:** `test/ella/tools/write_file_test.exs`

#### Steps
1. Set up a temp sandbox root (same pattern as Plan 1).
2. Test: write new file → `{:ok, "Successfully wrote …"}` → `File.read!` confirms content.
3. Test: overwrite existing file → old content is replaced.
4. Test: NBSP (`\u00A0`) in content is stripped before writing (the module calls `String.replace(content, " ", " ")`).
5. Test: path outside sandbox → `{:error, _}`.
6. Test: missing arguments → `{:error, "Invalid arguments …"}`.

**File to create:** (content in `test/ella/tools/write_file_test.exs`)

---

### Part B — `read_file`

**File to create:** `test/ella/tools/read_file_test.exs`

#### Steps
1. Set up temp sandbox.
2. Test: read whole file → returns numbered lines header + body.
3. Test: `offset` beyond end of file → returns "Offset X is past the end" message.
4. Test: `limit` clips at `@max_limit` (10 000) — write a file, pass `limit: 999_999`, confirm only 10 000 lines returned.
5. Test: `offset: 0` or `offset: -1` → `{:error, "read_file: 'offset' must be a positive integer …"}`.
6. Test: `limit: "bad"` → `{:error, …}`.
7. Test: file does not exist → `{:error, "Failed to read …"}`.
8. Test: path outside sandbox → `{:error, _}`.

---

### Part C — `approve`

**File to create:** `test/ella/approve_test.exs`

#### Steps
1. Test `interactive?/0`:
   - `Application.put_env(:ella, :interactive, false)` → returns `false`.
   - `Application.put_env(:ella, :interactive, true)` → returns `true`.
   - Env var `CI=true` set, no app env override → `interactive?()` returns `false`.
     *(Use `System.put_env/2` + `on_exit` cleanup.)*

2. Test `ask/2` in non-interactive mode:
   - `Application.put_env(:ella, :interactive, false)`
   - `Approve.ask("write_file", "lib/foo.ex")` → `:unavailable`.

3. Test `ask/2` with `require_approval: false`:
   - Set `interactive: true`, `require_approval: false`.
   - Capture output via `Ella.Output.set_sink/1` with a buffer.
   - `ask/2` → `:yes`, output contains "[protected]".

4. Test `refusal/1` and `unavailable/1` return the expected strings (pure functions, no side effects).

---

## Plan 3 — Add end-to-end (E2E) pipeline test (Medium Priority)

**Goal:** A single test that exercises the full user→LLM(stub)→tool call→tool result→LLM→reply pipeline through `Ella.Agent`.

**File to create:** `test/ella/agent_e2e_test.exs`

### Steps

#### Step 1 — Design a deterministic fake LLM adapter
```elixir
defmodule FakeSequenceAdapter do
  @moduledoc "Replays a pre-programmed sequence of LLM responses."

  def chat_completion(messages, _tools, opts) do
    sequence = Process.get(:fake_sequence, [])
    [next | rest] = sequence
    Process.put(:fake_sequence, rest)
    if on_text = opts[:on_text], do: on_text.(next[:content] || "")
    {:ok, next, Ella.Llm.Usage.empty()}
  end
end
```

#### Step 2 — Write the E2E test
Scenario: Agent asks LLM, LLM requests `echo` via `system_exec`, agent runs the tool, LLM returns final text.

```elixir
test "full loop: LLM calls tool, receives result, returns final answer" do
  Process.put(:fake_sequence, [
    # First call: LLM requests a tool
    %{"role" => "assistant", "tool_calls" => [
      %{"id" => "c1", "function" => %{"name" => "system_exec",
        "arguments" => ~s({"command":"echo hello"})}}
    ]},
    # Second call: LLM returns final answer
    %{"role" => "assistant", "content" => "Done. Output was: hello"}
  ])

  {:ok, pid} = Ella.Agent.start_link(llm_opts: [adapter: FakeSequenceAdapter], mode: :build)
  {:ok, _msgs, reply, _usage} = Ella.Agent.ask(pid, "run echo")

  assert reply =~ "Done"
  GenServer.stop(pid)
end
```

#### Step 3 — Add mode-transition test
- Start agent in `:plan` mode, call `set_mode(pid, :build)`, confirm `get_active_tools` includes `write_file`.

#### Step 4 — Add context-compaction integration test
- Pre-load agent with 50 large fake messages (> context budget).
- Call `ask/2` → verify the agent doesn't crash and returns a reply.

### Acceptance Criteria
- E2E test passes without hitting a real LLM.
- Tool result correctly appears in messages sent to the second LLM call.

---

## Plan 4 — Refactor `Ella.Agent` (Medium Priority)

**Goal:** Break the 871-line GenServer into focused sub-modules without changing public APIs.

### Proposed Structure

```
lib/ella/agent.ex              ← GenServer skeleton only (~250 lines)
lib/ella/agent/loop.ex         ← run_loop, continue_loop, finish_turn
lib/ella/agent/tool_runner.ex  ← execute_tool_call, execute_tool, build_tool_map
lib/ella/agent/streaming.ex    ← streaming_opts, finish_turn
lib/ella/agent/prompt.ex       ← update_system_prompt, skills_catalog, set_system_message
```

### Steps

#### Step 1 — Extract `Ella.Agent.ToolRunner`
Move to `lib/ella/agent/tool_runner.ex`:
- `execute_tool_call/4`
- `execute_tool/4`
- `build_tool_map/1`

Keep the same function signatures. `Ella.Agent` calls them via `Ella.Agent.ToolRunner.*`.

#### Step 2 — Extract `Ella.Agent.Loop`
Move to `lib/ella/agent/loop.ex`:
- `run_loop/4`
- `continue_loop/6`
- `calibrate/3`
- `prepare_context/2`

This module depends on `ToolRunner` and `Ella.Agent.Streaming`.

#### Step 3 — Extract `Ella.Agent.Streaming`
Move to `lib/ella/agent/streaming.ex`:
- `streaming_opts/1`
- `finish_turn/1`

#### Step 4 — Extract `Ella.Agent.Prompt`
Move to `lib/ella/agent/prompt.ex`:
- `update_system_prompt/1` (all three clauses)
- `set_system_message/2`
- `summary_message?/1`
- `skills_catalog/1`
- `publish_context/1`

#### Step 5 — Update `Ella.Agent`
- Delete extracted private functions.
- Add `alias Ella.Agent.{Loop, ToolRunner, Streaming, Prompt}`.
- Delegate `handle_call({:ask, …})` to `Loop.run_loop/4`.

#### Step 6 — Run full test suite
```bash
mix test --trace
```
No test should fail. No public API changes.

#### Step 7 — Add module-level tests for each extracted module
- `test/ella/agent/tool_runner_test.exs`: test MCP dispatch, atom tool dispatch, disabled-tool error messages.
- `test/ella/agent/loop_test.exs`: test iteration-limit path, context-too-large path.

### Acceptance Criteria
- `Ella.Agent` reduced to ≤ 300 lines.
- All 439 existing tests still pass.
- Each new sub-module has at least 3 unit tests.

---

## Plan 5 — Bump `mix.exs` version to `0.3.1` (Medium Priority — Trivial)

**Goal:** Keep `version` in sync with the latest git tag.

### Steps

1. Open [`mix.exs`](file:///Users/macbook/alexandra/my_coding_agent/mix.exs), line 6.
2. Change `version: "0.3.0"` → `version: "0.3.1"`.
3. Run `mix compile` — verify no errors.
4. Commit: `chore: bump version to 0.3.1`.

### Acceptance Criteria
- `mix run -e 'IO.puts Application.spec(:ella, :vsn)'` prints `0.3.1`.

---

## Plan 6 — Tighten `Req` version pin (Medium Priority — Trivial)

**Goal:** Prevent an accidental upgrade to a future Req 0.6/0.8 that might break `%Req.Response{}` pattern matching.

### Steps

1. Open [`mix.exs`](file:///Users/macbook/alexandra/my_coding_agent/mix.exs), deps section.
2. Change `{:req, "~> 0.5"}` → `{:req, "~> 0.7"}`.
3. Run `mix deps.get` — confirm no conflicts.
4. Run `mix test` — all 439 tests pass.
5. Commit: `chore: tighten Req version constraint to ~> 0.7`.

### Acceptance Criteria
- `mix deps` shows `req 0.7.x` locked.
- Full test suite passes.

---

## Plan 7 — Add `credo` and `dialyxir` (Low Priority)

**Goal:** Enable static analysis and type-checking as development tools.

### Steps

#### Step 1 — Add deps
In [`mix.exs`](file:///Users/macbook/alexandra/my_coding_agent/mix.exs) `deps/0`:
```elixir
{:credo, "~> 1.7", only: [:dev, :test], runtime: false},
{:dialyxir, "~> 1.4", only: [:dev], runtime: false}
```

#### Step 2 — Fetch and compile
```bash
mix deps.get
mix deps.compile
```

#### Step 3 — Generate Credo config
```bash
mix credo gen.config
```
Review `.credo.exs` and disable any checks that conflict with the existing codebase style (e.g., `Credo.Check.Readability.ModuleDoc` if Ukrainian docs are acceptable).

#### Step 4 — Fix Credo issues
```bash
mix credo --strict
```
Address issues by priority: `:error` and `:warning` first, `:refactor` and `:design` can be deferred.

#### Step 5 — Run Dialyzer (first run builds PLT — takes ~5 min)
```bash
mix dialyzer
```
Address any type errors found. Add `# dialyzer: ignore_warning` annotations only for genuinely false positives.

#### Step 6 — Add to CI (see Plan 10)
```yaml
- run: mix credo --strict
- run: mix dialyzer
```

### Acceptance Criteria
- `mix credo --strict` exits 0.
- `mix dialyzer` exits 0.

---

## Plan 8 — `WebSearch` alternative provider support (Low Priority)

**Goal:** Allow users to swap DuckDuckGo for Brave Search or Serper.dev via `WEB_SEARCH_PROVIDER` env var.

### Steps

#### Step 1 — Define provider behaviour
Create `lib/ella/tools/web_search/provider.ex`:
```elixir
defmodule Ella.Tools.WebSearch.Provider do
  @callback search(query :: String.t(), limit :: pos_integer()) ::
              {:ok, [map()]} | {:error, String.t()}
end
```

#### Step 2 — Move DuckDuckGo logic to its own module
Create `lib/ella/tools/web_search/duck_duck_go.ex`:
```elixir
defmodule Ella.Tools.WebSearch.DuckDuckGo do
  @behaviour Ella.Tools.WebSearch.Provider
  # Move search_duckduckgo/2 and all parsing helpers here
end
```

#### Step 3 — Add Brave provider (behind API key)
Create `lib/ella/tools/web_search/brave.ex`:
```elixir
defmodule Ella.Tools.WebSearch.Brave do
  @behaviour Ella.Tools.WebSearch.Provider

  @api_url "https://api.search.brave.com/res/v1/web/search"

  def search(query, limit) do
    key = System.get_env("BRAVE_SEARCH_API_KEY") || ""
    # Req.get(@api_url, params: [q: query, count: limit], headers: [{"X-Subscription-Token", key}])
    # Parse JSON response
  end
end
```

#### Step 4 — Add provider dispatch in `WebSearch`
```elixir
defp provider_module do
  case System.get_env("WEB_SEARCH_PROVIDER", "duckduckgo") do
    "brave"  -> Ella.Tools.WebSearch.Brave
    "serper" -> Ella.Tools.WebSearch.Serper
    _        -> Ella.Tools.WebSearch.DuckDuckGo
  end
end
```

#### Step 5 — Update `do_search/2`
Replace the direct `search_duckduckgo/2` call with `provider_module().search(query, limit)`.

#### Step 6 — Tests
- Add a test that sets `WEB_SEARCH_PROVIDER=duckduckgo` and stubs the HTTP call → original behaviour preserved.
- Add a test for `brave` provider that stubs `Req.get` and asserts correct header is sent.

### Acceptance Criteria
- `WEB_SEARCH_PROVIDER=duckduckgo mix test` → all tests pass.
- `WEB_SEARCH_PROVIDER=brave mix test` with a stub → brave path exercised.
- `WEB_SEARCH_PROVIDER=unknown` → falls back to DuckDuckGo.

---

## Plan 9 — Translate Ukrainian `@doc` / `@moduledoc` to English (Low Priority)

**Goal:** Make the codebase accessible to non-Ukrainian speakers for open-source or team use.

### Affected files (all have Ukrainian-only docs)
| File | Key docs |
|------|----------|
| [`lib/ella/context.ex`](file:///Users/macbook/alexandra/my_coding_agent/lib/ella/context.ex) | All `@doc` strings, `@moduledoc` |
| [`lib/ella/skills.ex`](file:///Users/macbook/alexandra/my_coding_agent/lib/ella/skills.ex) | `@moduledoc`, some `@doc` |
| [`lib/ella/approve.ex`](file:///Users/macbook/alexandra/my_coding_agent/lib/ella/approve.ex) | `@moduledoc`, `@doc` |
| [`lib/ella/agent.ex`](file:///Users/macbook/alexandra/my_coding_agent/lib/ella/agent.ex) | Inline comments throughout |
| [`lib/ella/sub_agent.ex`](file:///Users/macbook/alexandra/my_coding_agent/lib/ella/sub_agent.ex) | Inline comments |
| [`lib/ella/mcp/client.ex`](file:///Users/macbook/alexandra/my_coding_agent/lib/ella/mcp/client.ex) | Inline comments |
| [`lib/ella/tools/read_file.ex`](file:///Users/macbook/alexandra/my_coding_agent/lib/ella/tools/read_file.ex) | `@moduledoc` |

### Steps

1. For each file, translate `@moduledoc` and `@doc` attributes **in place** — keep the same structure, just change language.
2. Translate significant inline comments (single-line `#` comments that explain non-obvious logic). Leave trivial comments (`# --- Section ---` headers) as-is or in English.
3. Do **not** change code, only string literals inside `@doc`/`@moduledoc` and `#` comments.
4. After each file, run `mix test` to confirm no regressions.
5. Commit per file: `docs(context): translate module docs to English`.

### Acceptance Criteria
- `mix docs` (if ExDoc is added) renders all pages in English.
- No test regressions.

---

## Plan 10 — Add CI pipeline (Low Priority)

**Goal:** Automatically run tests, format check, and static analysis on every push and pull request.

### Steps

#### Step 1 — Create workflow file
Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    name: Test (OTP ${{ matrix.otp }} / Elixir ${{ matrix.elixir }})
    runs-on: ubuntu-latest

    strategy:
      matrix:
        otp: ["27.0"]
        elixir: ["1.17"]

    steps:
      - uses: actions/checkout@v4

      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ matrix.otp }}
          elixir-version: ${{ matrix.elixir }}

      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}

      - name: Install dependencies
        run: mix deps.get

      - name: Check formatting
        run: mix format --check-formatted

      - name: Compile (warnings as errors)
        run: mix compile --warnings-as-errors

      - name: Run tests
        run: mix test --cover

      # Uncomment after Plan 7 is complete:
      # - name: Credo
      #   run: mix credo --strict
```

#### Step 2 — Add a `.tool-versions` file (asdf)
```
elixir 1.17.3-otp-27
erlang 27.0
```
This keeps CI and local environments in sync.

#### Step 3 — Add a test coverage badge to `README.md`
```markdown
![CI](https://github.com/<org>/ella/actions/workflows/ci.yml/badge.svg)
```

#### Step 4 — Protect `main` branch
In GitHub Settings → Branches → Add rule:
- Require status checks: `test` job must pass.
- Require branches to be up to date before merging.

### Acceptance Criteria
- Every push to `main` triggers the workflow.
- A failing test blocks a PR from being merged.
- `mix format --check-formatted` failure is surfaced within 2 minutes.

---

## Summary Table

| # | Improvement | Effort | Priority | Files Touched |
|---|-------------|--------|----------|---------------|
| 1 | Test `apply_patch` | Medium | 🔴 High | `test/ella/tools/apply_patch_test.exs` (new) |
| 2 | Test `write_file`, `read_file`, `approve` | Low | 🔴 High | 3 new test files |
| 3 | E2E pipeline test | Medium | 🟡 Medium | `test/ella/agent_e2e_test.exs` (new) |
| 4 | Refactor `Ella.Agent` | High | 🟡 Medium | `lib/ella/agent/*.ex` (new), `agent.ex` |
| 5 | Bump version to `0.3.1` | Trivial | 🟡 Medium | `mix.exs` |
| 6 | Tighten `Req` version | Trivial | 🟡 Medium | `mix.exs` |
| 7 | Add `credo` + `dialyxir` | Low | 🟢 Low | `mix.exs`, `.credo.exs` |
| 8 | `WebSearch` provider dispatch | High | 🟢 Low | `lib/ella/tools/web_search/*.ex` (new) |
| 9 | Translate docs to English | Medium | 🟢 Low | 7 existing source files |
| 10 | CI pipeline | Low | 🟢 Low | `.github/workflows/ci.yml` (new) |
