# Team Presets

A team preset is an additive config overlay that seeds a ready-to-boot set of
keepers (with their personas) into a live MASC config root. It exists because
config seeding intentionally excludes `keepers/` and `personas/` — a fresh
install boots zero keepers until an operator opts a team in.

`scripts/seed-team.sh <preset> <base-path>` copies a preset's `keepers/` and
`personas/` into `<base-path>/.masc/config/`. The four team keepers inherit
`[runtime].default` from `runtime.toml` (shipped as
`ollama_cloud.deepseek-v4-flash`), so a preset never edits the model catalog and
stays coherent with `runtime.toml` and OAS's embedded catalog plus the
deployment `oas-models-overlay.toml` by construction.

Presets live at the repo top level (`presets/`), not under `config/`, so the
server's config-root bootstrap never copies them into a live runtime config
root — they are install-time seed sources, not runtime config.

## Layout

```
presets/<preset>/
  manifest.txt                 # SSOT file list (seed-team.sh + install.sh read it)
  keepers/base.toml            # loader template, autoboot_enabled = false
  keepers/<name>.toml          # one per keeper, autoboot_enabled = true
  personas/<name>/profile.json # persona for each keeper
```

`manifest.txt` is the single source of truth for which files a preset ships.
`seed-team.sh` copies them from the local repo/image; `install.sh --team` fetches
the same list over `raw.githubusercontent.com` for the `curl | bash` path. Keep
the manifest in sync when adding or removing preset files.

## classic

A conventional software team: `tech_lead`, `backend`, `frontend`, `qa`. The tech
lead breaks requirements into tasks and reviews PRs; backend and frontend
implement; QA verifies. All four run on `ollama_cloud.deepseek-v4-flash`.

`keepers/base.toml` sets `sandbox_profile = "local"` (not `"docker"`) so the
demo boots cleanly when the server itself runs inside a container — see the
comment in that file for the Docker-in-Docker rationale and the host-native
override.
