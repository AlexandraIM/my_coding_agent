---
name: Git hygiene
description: Keep changes small and reviewable; never auto-commit
tools: [system_exec, read_file]
---
Before editing, run `git status` and `git diff --stat` to understand the working tree. After editing, show `git diff --stat` and the changed file names. Do not commit, push, or create branches unless the user explicitly asks. Prefer one logical change per commit and a message that explains why.
