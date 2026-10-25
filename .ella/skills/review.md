---
name: Code review
description: Structured review checklist for a change
tools: [read_file, grep, glob, system_exec]
---
Review a change by: (1) reading the diff (`git diff`, `git diff --staged`), (2) reading touched files in full when the diff is insufficient, (3) running the project's checks.

Focus on correctness, edge cases, error handling, missing tests, and security (injection, secrets, path traversal). Skip pure style unless it affects correctness. Separate blocking issues from nits. End with a verdict: approve or request changes.
