---
rfc: "0141"
title: "TOML Field Resolution Typed Variant for repo_manager"
status: Implemented
created: 2026-05-20
updated: 2026-06-02
author: vincent
supersedes: []
superseded_by: null
related: ["0088", "0126", "0142", "0148", "0154"]
---

# RFC-0141 — TOML Field Resolution Typed Variant

## 1. Summary

Use a typed `Field_resolution.t` variant that distinguishes an absent field
from a schema type mismatch.

The live scope is repository config parsing:

- `lib/repo_manager/field_resolution.ml`
- `lib/repo_manager/field_resolution.mli`
- `lib/repo_manager/repo_store.ml`

The former repository credential half of this RFC is retired with the
repo-manager credential store deletion.

## 2. Behavior

Repository catalog callers require every field emitted by the current writer.
Both absence and type mismatch are errors at that boundary.

Example:

```ocaml
match Field_resolution.resolve_string toml (path "local_path") with
| Present value -> Ok value
| Missing -> Error "required local_path is absent"
| Type_mismatch _ -> Error "local_path must be a string"
```

If `repositories.toml` declares `local_path = 42`, repository parsing returns an
error naming the field.

## 3. Contract

- Only rows containing every field emitted by the current writer are valid.
- Missing and wrong-typed repository fields are rejected.
- Unknown repository fields are rejected.

## 4. Verification

- Unit coverage for `Field_resolution` variants.
- Repository store tests for complete round-trip parsing and schema
  rejection.
- No repo-manager credential parser, materializer, route, or dashboard surface
  remains in scope.
