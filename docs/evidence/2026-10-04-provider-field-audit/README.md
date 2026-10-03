# Provider field decoding: K2

Base: `95bac64e3918a191c66507515975437feb3e8235` (K1 PR #41060).

`parse_provider` read selected fields without rejecting unknown names. A
`model_set` typo was ignored by both that parser and the shared-binding reader,
which only reads `model-set`. Explicit bindings could hide the missing generated
bindings and permit an unintended runtime configuration to load.

The provider table now rejects fields outside the set consumed by its provider
and shared-binding readers, with the precise TOML field path. Protocol-specific
validation still rejects fields illegal for the chosen protocol. Ordinary,
inline and dotted TOML tables use the same check. Non-table provider declarations
return a structured parse error.

## Validation

Three changed OCaml files pass parser-only checks, and git diff --check passes.
Three authored native cases cover the canonical spelling against the typo, both
with and without explicit bindings; inline/dotted/nested unknown fields;
account_home typo; malformed provider table; and the actual Runtime.load_list
file boundary including the config path and offending field in its diagnostic.
Existing generated-binding/materialization and provider protocol cases remain.

Native cases have not been run. No typecheck, Dune build, CI, live config write,
server restart or production claim. This parser repair changes no dashboard
rendering; no browser screenshot is claimed.
