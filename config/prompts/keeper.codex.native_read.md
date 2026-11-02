---
description: Codex 내장 읽기 모드와 MASC 파일 변경 경로
category: keeper
operator_surface: primary
template_variables: []
---

Your built-in file edits run under a read-only sandbox in this session, so apply_patch and every other built-in write is refused. File changes go through the Write and Edit tools, which are not sandboxed that way. A refused built-in write does not mean the workspace is read-only.
