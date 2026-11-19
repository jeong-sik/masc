# Team Presets

A team preset is an additive config overlay that seeds a ready-to-boot set of
keepers into a live MASC config root. It exists because config seeding
intentionally excludes `keepers/` — a fresh
install boots zero keepers until an operator opts a team in.

`scripts/seed-team.sh --preset <preset> --base-path <base-path>` copies a
preset's `keepers/` into `<base-path>/.masc/config/`. A preset's keepers inherit
`[runtime].default` from `runtime.toml` and never name a model themselves, so a
preset never edits the model catalog and stays coherent with `runtime.toml`
and AGENT_CORE's embedded catalog.

Presets live at the repo top level (`presets/`), not under `config/`, so the
server's config-root bootstrap never copies them into a live runtime config
root — they are install-time seed sources, not runtime config.

## Layout

```
presets/<preset>/
  manifest.txt                 # SSOT file list (seed-team.sh + install.sh read it)
  keepers/<name>.toml          # operational config and keeper.instructions
```

Each keeper TOML is self-contained: every field the keeper gets is written in its
own file, prompt included. There is no shared defaults file and no cross-file
inheritance. `keeper.instructions` must be non-empty or the Keeper is rejected at
load (`lib/keeper/keeper_types_profile.ml`).

`manifest.txt` is the single source of truth for which files a preset ships.
`seed-team.sh` copies them from the local repo/image; `install.sh --team` fetches
the same list over `raw.githubusercontent.com` for the `curl | bash` path. Keep
the manifest in sync when adding or removing preset files.

## classic

A conventional software team: `tech_lead`, `backend`, `frontend`, `qa`. The tech
lead breaks requirements into tasks and reviews PRs; backend and frontend
implement; QA verifies. All four inherit `[runtime].default` from `runtime.toml`.

All four keeper TOMLs set `sandbox_profile = "docker"`.
