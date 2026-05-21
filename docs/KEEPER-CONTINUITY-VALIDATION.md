# Keeper Continuity Validation

Status: operator validation harness  
Updated: 2026-03-11

## Goal

`keeper continuity`가 실제 live runtime에 의해 증명되는지 검증한다.

이 문서와 harness는 아래를 구분하기 위해 존재한다.

- 단순 keeper 메타/대시보드 카드
- stale history 또는 persisted summary
- 실제로 살아 있는 keeper runtime

## What counts as real live continuity

이 harness에서 `PASS`로 간주하려면 아래가 모두 충족되어야 한다.

1. room keepalive / agent presence 신호가 실제로 보인다
2. `masc_keeper_msg` 이후 recent turn이 갱신된다
3. `continuity_summary`와 `last_continuity_update_ts`가 실제 turn 이후 전진한다
4. compaction evidence가 발생한다
5. handoff evidence가 발생한다
6. 같은 keeper name으로 restart 후 다시 live turn이 성공한다

이 중 1-3만 충족되면 `PARTIAL`이다.  
1-3 중 하나라도 실패하면 `FAIL`이다.

실제 구현상 keeper keepalive는 `masc_heartbeat_list` 전용 registry와 1:1 대응하지 않는다.  
따라서 이 harness의 liveness 신호는 기본적으로 아래 3개를 사용한다.

- `keepalive_running=true`
- `agent.exists=true`
- `last_turn_ago_s`가 fresh range 안으로 갱신됨

`masc_heartbeat_list` 출력은 참고용 artifact로만 저장한다.

## Why this is neutral

- 기본값은 dedicated temporary server + temporary base path를 사용한다
- 기존 keeper, 기존 `.masc`, 기존 room과 섞이지 않는다
- dashboard 카드가 아니라 MCP truth를 직접 읽는다
- raw thinking은 보고하지 않고 최근 input/output preview와 구조화된 상태 필드만 남긴다

## Commands

Dry-run plumbing check:

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp
DRY_RUN=1 scripts/harness_keeper_continuity_validation.sh
```

`DRY_RUN=1` is for harness plumbing only. It validates artifact/report generation, not real runtime continuity.

Real isolated validation:

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp
KEEPER_MODELS="default" \
scripts/harness_keeper_continuity_validation.sh
```

Use an existing MCP server instead of starting a temp one:

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp
START_SERVER=0 \
MCP_URL="http://127.0.0.1:8935/mcp" \
KEEPER_MODELS="default" \
scripts/harness_keeper_continuity_validation.sh
```

## Key knobs

- `KEEPER_MODELS`
  - required in real mode
- `START_SERVER`
  - default `1`
- `PORT`
  - optional explicit temp port
- `BASE_PATH`
  - optional explicit isolated base path
- `KEEP_ARTIFACTS`
  - keep temp server base path for debugging
- `MAX_TURNS`
  - default `4`
- `TARGET_PHASES`
  - default `bootstrap,liveness,continuity,compaction,handoff,recovery`

## Default validation profile

The harness intentionally uses aggressive test-only keeper settings:

- `proactive_enabled=false`
- `auto_handoff=true`
- `compaction_profile=custom`
- `compaction_ratio_gate=0.10`
- `compaction_message_gate=2`
- `continuity_compaction_cooldown_sec=0`
- `handoff_threshold=0.01`
- `context_budget=0.60`
- `drift_enabled=false`

These values are for validation only. They are not production keeper policy.
Keeper는 durable always-on이므로 keepalive 자체는 개별 설정이 아니라 내부 런타임 동작으로 취급한다.

## Output artifacts

Artifacts are written to:

```text
logs/keeper_continuity/<run_id>/
```

Files:

- `manifest.json`
- `phases.jsonl`
- `summary.json`
- `summary.md`
- `snapshots/`
- `raw/`
- `server.log`

## How to read the result

### PASS

The runtime proved that a keeper was actually alive and continuity transitions were real.

### PARTIAL

The keeper was live and continuity updated, but compaction or handoff did not occur within the validation window.

Typical causes:

- prompt pressure too low
- model too small/too fast to accumulate pressure
- timeout window too short

### FAIL

The harness only observed stale metadata or dead keeper state.

Typical causes:

- room keepalive signal never appeared
- `agent.exists` stayed false
- turn never updated after `masc_keeper_msg`
- restart did not restore live behavior

## Related references

- `docs/KEEPER-SOCIAL-EXPERIMENT-DESIGN.md`
- `scripts/run_trpg_longplay_liveliness.sh`
- `skills/masc-keeper-autonomy/SKILL.md`
