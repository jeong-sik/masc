---
rfc: "0198"
title: Execute typed redirection
status: Implemented
created: 2026-05-27
updated: 2026-08-08
related: []
---

# Execute typed redirection

## Contract

`tool_execute` accepts an executable argument vector. Every `argv` element is
passed verbatim to the child process; shell metacharacters are not interpreted.
Redirection is represented by the typed `stdin`, `stdout`, and `stderr` fields.

```ocaml
type redirect_target =
  | Inherit
  | Discard
  | File of string
```

`File` requires a validated absolute path. The parser rejects redirection-shaped
tokens in `argv`; callers must use the typed fields instead.

## Owners

- `lib/keeper/keeper_tool_execute_typed_input.ml` parses and validates the
  command and redirection fields.
- `lib/keeper/keeper_tool_execute_shell_ir.ml` projects the typed command to
  Shell IR.
- `lib/tool_surface/tool_shard_types_schemas_execute.ml` owns the public schema.
- `lib/exec/exec_dispatch.ml` executes the resulting Shell IR.

## Required invariants

- No shell-line parser is applied to `argv`.
- Redirection-shaped `argv` tokens fail at the typed input boundary.
- Relative file redirection targets are rejected.
- Each redirect target is lowered exhaustively to Shell IR.
- Descriptor examples use typed redirection fields.

## Verification

`test/test_keeper_tool_execute_typed_input.ml` covers typed parsing, invalid
targets, and Shell IR lowering. The descriptor tests pin the same schema exposed
to model callers.
