# `cascade.toml` Manual

Authoring guide for the checked-in cascade seed and live per-base-path config.

## Start Here

- Live config root: `$MASC_BASE_PATH/.masc/config/cascade.toml`
- Repo seed/fallback: [`config/cascade.toml`](../config/cascade.toml)
- Materialized runtime artifact: [`config/cascade.json`](../config/cascade.json)

`config/cascade.toml` is the supported human-authored source when present. The
runtime materializes sibling `cascade.json` before loading.

## Checked-In Seed Policy

The repo seed should stay intentionally small.

- Keep the checked-in keeper-assignable set explicit and boring:
  `big_three` for keeper/general turns.
- Keep system-only lanes explicit and minimal: `tool_rerank` for short
  rerank/scoring calls.
- Put logical usages such as `governance_judge`, `operator_judge`,
  `local_recovery`, `tool_use_strict`, `cross_verifier`, and `autoresearch`
  under `[routes]`. They are route keys, not profile names.
- Put personal experiments, vendor mixes, and machine-specific profiles in
  live config under `$MASC_BASE_PATH/.masc/config/cascade.toml`, not in the
  repo seed

This keeps bootstrap defaults reviewable and avoids turning repo config into a
graveyard of personal cascade variants.

## Seed Profiles

- `big_three`: canonical keeper/workflow profile.
- `tool_rerank`: system-only short-output profile.

## Routes

`[routes]` maps logical call-site names to concrete profiles:

```toml
[routes]
governance_judge = "big_three"
operator_judge = "big_three"
cross_verifier = "big_three"
llm_rerank = "tool_rerank"
```

Runtime code must use the logical route key and let config choose the concrete
profile. Do not add a new checked-in profile just because one call site needs a
name.

The runtime validates `[routes]` against the code route registry. Unknown route
keys are rejected as config/code drift, and route targets must name an active
profile in the same catalog.

Use `keeper_assignable = false` for profiles that must exist in the catalog but
must not appear as normal keeper choices.

## Edit Workflow

1. Edit [`config/cascade.toml`](../config/cascade.toml).
2. Materialize the runtime artifact:

```bash
dune exec --root . ./bin/cascade_materialize.exe -- config/cascade.json
```

The materializer takes the runtime JSON path/candidate and uses sibling
`cascade.toml` when present.

3. Run focused checks:

```bash
dune runtest --root . test/test_cascade_config_validity.exe
dune exec --root . ./test/test_keeper_cascade_profile.exe
```

## What Belongs In Repo vs Live Config

Add a checked-in profile only when at least one of these is true:

- a checked-in keeper depends on it
- the profile has materially different model/parameter behavior from the two
  defaults

Otherwise, put it in live config or a private/local cookbook-derived setup.

## Related Docs

- Extended local/private examples: [`docs/CASCADE-COOKBOOK.md`](./CASCADE-COOKBOOK.md)
- Reload semantics: [`docs/TOML-RELOAD-MATRIX.md`](./TOML-RELOAD-MATRIX.md)
- Schema reference: [`docs/spec/14-configuration.md`](./spec/14-configuration.md)
- Cascade design index: [`docs/cascade/README.md`](./cascade/README.md)
