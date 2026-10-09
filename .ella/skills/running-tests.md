---
name: Running tests
description: How to run the test suite in this project and what to expect
---

Run the full suite with:

```sh
mix test
```

Run a single file:

```sh
mix test test/ella/skills_test.exs
```

Run tests matching a name:

```sh
mix test --only test:"test name"
```

Always run `mix test` after changing code in `lib/`. If it fails, fix the cause
rather than loosening the assertion.
