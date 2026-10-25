---
name: Refactoring
description: Change structure without changing behavior
tools: [read_file, grep, glob, apply_patch, system_exec]
---
Keep behavior identical. Run tests before and after. One refactor per change. Do not mix refactoring with feature work. Do not rename or reformat unrelated code.
