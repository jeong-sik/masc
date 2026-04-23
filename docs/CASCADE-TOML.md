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

- Keep exactly one keeper-assignable bootstrap profile: `big_three`
- Keep system-only plumbing profiles checked in only when runtime routing needs
  them: `default`, `governance_judge`, `operator_judge`, `local_only`, `local_recovery`, `tool_rerank`
- Put personal experiments, vendor mixes, and machine-specific profiles in
  live config under `$MASC_BASE_PATH/.masc/config/cascade.toml`, not in the
  repo seed

This keeps bootstrap defaults reviewable and avoids turning repo config into a
graveyard of personal cascade variants.

## Seed Profiles

- `default`: fallback for unknown/missing cascade names. Keep it boring and
  close to `big_three`.
- `big_three`: canonical keeper bootstrap profile for checked-in keepers.
- `governance_judge`: system-only dashboard governance judge profile.
- `operator_judge`: system-only dashboard operator judge profile.
- `local_only`: system-only local lane used by phase routing during compacting
  and handoff paths.
- `local_recovery`: system-only local recovery lane used after provider/cloud
  failures.
- `tool_rerank`: system-only short-output override. It has no own model list
  and reuses the default cascade models.

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
- phase-routing/runtime recovery depends on it
- operators need the same boring default everywhere

Otherwise, put it in live config or a private/local cookbook-derived setup.

## Related Docs

- Extended local/private examples: [`docs/CASCADE-COOKBOOK.md`](./CASCADE-COOKBOOK.md)
- Reload semantics: [`docs/TOML-RELOAD-MATRIX.md`](./TOML-RELOAD-MATRIX.md)
- Schema reference: [`docs/spec/14-configuration.md`](./spec/14-configuration.md)
- Cascade design index: [`docs/cascade/README.md`](./cascade/README.md)
