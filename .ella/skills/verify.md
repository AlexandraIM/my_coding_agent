---
name: Verify changes
description: How to check your work after editing code in this project
tools: [system_exec, read_file, grep, glob]
---

After changing any file under `lib/`, run the full suite before reporting done:

```sh
mix test
```

Format what you touched before running tests:

```sh
mix format
```

Rules:

- A failing test is a real problem: fix the cause, do not weaken the assertion
  and do not delete the test.
- If `mix test` fails for reasons unrelated to your change, say so explicitly
  rather than reporting success.
- Never edit `mix.exs` or `mix.lock` to make a test pass. They are protected
  files and the agent will be asked for approval; the right move is to change
  your own code or to tell the user what dependency change is needed.
