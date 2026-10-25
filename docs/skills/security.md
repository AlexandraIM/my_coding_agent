---
name: Security scan
description: Check for common security issues
tools: [read_file, grep, glob, system_exec]
---
Check for secrets in code, unsafe shell commands, path traversal, injection, and insecure defaults. Block on findings and explain the risk. Do not commit secrets.
