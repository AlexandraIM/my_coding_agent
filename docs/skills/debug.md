---
name: Debugging
description: Reproduce, minimize, hypothesize, fix, and add a regression test
tools: [read_file, grep, glob, system_exec]
---
Reproduce the bug first. Minimize the input. Form a hypothesis, instrument to confirm, then fix the root cause. Add a regression test that fails before the fix and passes after. Never guess.
