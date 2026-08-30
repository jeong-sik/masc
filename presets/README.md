# Team Presets

A team preset is an additive config overlay that seeds a ready-to-boot set of
keepers into a live MASC config root. It exists because config seeding
intentionally excludes `keepers/` — a fresh
install boots zero keepers until an operator opts a team in.

`scripts/seed-team.sh <preset> <base-path>` copies a preset's `keepers/` and
into `<base-path>/.masc/config/`. The four team keepers inherit
`[runtime].default` from `runtime.toml` (shipped as
`ollama_cloud.deepseek-v4-flash`), so a preset never edits the model catalog and
stays coherent with `runtime.toml` and AGENT_CORE's embedded catalog plus the
deployment `agent-core-models-overlay.toml` by construction.

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
implement; QA verifies. All four run on `ollama_cloud.deepseek-v4-flash`.

All four keeper TOMLs set `sandbox_profile = "local"` (not `"docker"`).

WORKAROUND: the quick-start install can run the MASC server itself inside a
Docker container. With `sandbox_profile = "docker"` each keeper Execute would
spawn a nested container (Docker-in-Docker), which needs a mounted host docker
socket and fails closed on a plain `docker compose up`. The classic-team demo
keepers collaborate over the board/tasks/chat and do not require
container-isolated shell execution to show the dashboard working. The
one-click image therefore sets `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1` explicitly;
the global server default remains fail-closed outside that image.
Root fix: when running the server natively on a host (not in a container),
override to `sandbox_profile = "docker"` per keeper for real Execute isolation,
or mount `/var/run/docker.sock` into the server container and switch back.
