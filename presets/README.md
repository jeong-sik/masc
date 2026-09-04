# Team Presets

A team preset is an additive config overlay that seeds a ready-to-boot set of
keepers into a live MASC config root. It exists because config seeding
intentionally excludes `keepers/` — a fresh
install boots zero keepers until an operator opts a team in.

`scripts/seed-team.sh <preset> <base-path>` copies a preset's `keepers/` and
into `<base-path>/.masc/config/`. A preset's keepers inherit
`[runtime].default` from `runtime.toml` and never name a model themselves, so a
preset never edits the model catalog and stays coherent with `runtime.toml` and AGENT_CORE's embedded catalog plus the
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
implement; QA verifies. All four inherit `[runtime].default` from `runtime.toml`.

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

## world-* — 가치 체계만 바꾸는 프리셋 묶음

`world-` 로 시작하는 18 개 프리셋은 하나의 실험 장치다. 네 자리의 **역할은 같고 재화만
다르다**. 같은 태스크를 주고 무엇을 성공으로 치는지만 바꿔서, 그 차이가 행동에 어떻게
나타나는지 본다.

설계, 재화 축, 실재했던 사회 형태의 출처, 무엇을 잴지는 세 문서에 있다.

- `docs/design/world-presets.md` — 설계와 세계 목록
- `docs/design/world-presets-research.md` — 형태의 출처와 경계
- `docs/design/world-presets-measurement.md` — 원장에서 읽을 값

### 네 자리는 모든 세계에서 같은 파일 이름이다

`arbiter`, `maker`, `witness`, `dissenter`. 이건 취향이 아니라 제약이다.
`Prompt_preset.restore_instructions` 는 keeper TOML 파일 이름으로 대상을 찾고 파일이
없으면 `"no keeper TOML"` 로 건너뛴다 (`lib/prompt_preset.ml`). 이름이 세계마다 다르면
`/preset restore` 로 세계를 갈아끼울 수 없다.

넷 중 셋이 세계에 동조하고 `dissenter` 하나가 반발한다. 3 대 1, 곧 75 대 25 다.

### 한 base path 에는 한 세계만 산다

파일 이름이 같으므로 나중에 seed 한 세계가 앞 세계를 덮는다 (`--force` 없이는 skip).
두 세계를 동시에 돌리려면 base path 를 나눈다.

```
scripts/seed-team.sh --preset world-capital  --base-path ~/lab/capital
scripts/seed-team.sh --preset world-scarcity --base-path ~/lab/scarcity
```

운영 중 갈아끼우기는 TUI 의 `/preset save <name>` 과 `/preset restore <name>` 을 쓴다.
`restore` 는 덮기 전에 현재 상태를 `_autosave-<stamp>` 로 저장하므로 되돌릴 길이 남는다.
instructions 는 각 keeper 의 다음 up 에서 반영된다.

### autoboot 와 proactive 가 켜져 있다

모든 world keeper 가 `autoboot_enabled = true`, `proactive_enabled = true` 다. 실험이
사람의 재촉 없이 돌아야 하기 때문이다. seed 하면 다음 기동에서 넷이 스스로 움직이고
토큰을 쓴다. 그걸 원하지 않으면 seed 하기 전에 해당 값을 끄거나 별도 base path 를 쓴다.

### 도구면은 세계마다 같다

`sandbox_profile = "local"`, `network_mode = "inherit"`, 도구 제한 없음. 세계마다 다르면
비교되는 게 가치 체계가 아니라 권한이 된다. 호스트에서 네이티브로 돌릴 때 실제 격리가
필요하면 `install.sh --sandbox docker` 로 일괄 덮거나 seed 후 각 파일에서 바꾼다.
