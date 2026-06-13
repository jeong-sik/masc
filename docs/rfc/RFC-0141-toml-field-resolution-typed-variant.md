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
implementation_prs: [16837, 16887]
---

# RFC-0141 — TOML Field Resolution Typed Variant

## 1. Summary

Replace `Otoml.find_result toml ... |> function Ok v -> Ok v | Error _ -> Ok default`
with a typed `Field_resolution.t` variant that distinguishes a legitimate
missing field from a schema type mismatch.

The live scope is repository config parsing:

- `lib/repo_manager/field_resolution.ml`
- `lib/repo_manager/field_resolution.mli`
- `lib/repo_manager/repo_store.ml`

The former repository credential half of this RFC is retired with the
repo-manager credential store deletion.

## 2. Behavior

`Field_resolution.or_default` substitutes defaults only for missing fields.
Type mismatches propagate as errors, so corrupt repository TOML is not silently
accepted.

Example:

```ocaml
let* local_path =
  Field_resolution.(
    resolve_string toml (path "local_path")
    |> or_default ~default:(default_local_path id))
in
```

If `repositories.toml` declares `local_path = 42`, repository parsing returns an
error naming the field instead of silently selecting a default path.

## 3. Compatibility

- Valid repository TOML remains valid.
- Missing optional repository fields keep their defaults.
- Wrong-typed repository fields are rejected.
- No repository credential TOML compatibility path exists.

## 4. Verification

- Unit coverage for `Field_resolution` variants and helpers.
- Repository store tests for defaults, round-trip parsing, and wrong-type
  rejection.
- No repo-manager credential parser, materializer, route, or dashboard surface
  remains in scope.
