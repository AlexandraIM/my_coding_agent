---
name: Verify changes
description: Run the project's checks after editing code
tools: [system_exec, read_file]
---
After changing any file under `lib/` or `src/`, detect and run the project's test command:

- Elixir: `mix test`
- Python: `pytest`
- Rust: `cargo test`
- Go: `go test ./...`
- Node: `npm test`

Report the real output. A change is not done until the relevant checks pass. If you could not run them, say so plainly. Never weaken or delete an assertion to make the suite green.
