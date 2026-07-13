---
status: deprecated
last_verified: 2026-04-23
---

# Command Plane Runbook — DEPRECATED

> **이 문서와 Command Plane(CP) 전체가 제거 예정입니다.**
>
> CP는 keeper 실행과 결합되지 않은 별도 ledger였고, 양방향 cross-reference가 0줄입니다. HTTP `/api/v1/command-plane/*` 표면은 supported product surface에서 이미 제거되었고, 이 문서는 historical migration context만 보존합니다.
>
> 새 코드는 CP에 의존하지 마십시오. 진짜 조정 경로는 `board_posts.jsonl` + keeper FSM + namespace/task hygiene입니다.
>
> 이 문서는 purge 기간 동안 historical reference로만 남겨집니다.

Historical Command Plane usage note.

이 문서는 retired Command Plane 흐름의 역사적 사용 순서를 정리한다. 기본 delivery 경로는 namespace/task hygiene와 supervisor-driven supervised execution이고, managed operation은 current implementation path가 아니다.

merged 기준 전체 구조 요약은 [spec/SPEC-INDEX.md](./spec/SPEC-INDEX.md)와 [spec/01-system-overview.md](./spec/01-system-overview.md)를 본다.

## 개념 맵

- `namespace`
  - 조율 범위. tool 이름은 아직 `workspace`을 쓰지만 현재 구현은 `<base-path>/.masc/`의 single default namespace로 수렴한다.
- `task`
  - backlog item. `masc_transition(action="claim")`은 backlog 소유권만 바꾸고 planning `current_task`는 자동으로 안 잡힌다. `masc_claim_next`는 current builds에서 planning `current_task`를 함께 맞춘다.
- `operation`
  - retired managed-operation ledger의 관리 단위. default delivery path는 아니다.
- `session`
  - historical supervised implementation execution unit. current workspace collaboration truth is board posts + keeper FSM, not CP session/detachment state.
- `detachment`
  - scheduler가 materialize한 실행 단위. liveness, runtime binding, heartbeat를 여기서 본다.
- `policy decision`
  - strict action 승인 큐. cross-platoon move, freeze, kill-switch 같은 작업이 여기에 멈춘다.
- `trace`
  - operation/checkpoint/dispatch/policy lineage.

## Golden Path 1. Namespace / Task Hygiene

일반 작업이든 benchmark든 먼저 이 순서를 맞춘다.

Quick path: `masc_start(path="/repo", task_title="My task")` — 1번을 처리하고, `task_title`이 있으면 task create/claim/bind까지는 옵션으로 도와줄 수 있다.

Step-by-step:

1. `masc_start`
   - project root를 workspace collaboration root로 잡고 default namespace join까지 처리한다.
   - `task_title` 없이 호출하면 onboarding만 하고 task claim 단계는 건너뛴다.
   - worktree 경로를 줘도 runtime namespace는 project-root 기준 default namespace로 수렴한다.
2. `masc_status`
   - namespace 상태와 agent roster를 확인한다.
3. `masc_transition(action="claim")` 또는 `masc_claim_next`
   - 작업을 claim한다. backlog가 비어 있으면 먼저 `masc_add_task`.
4. 필요 시 `masc_plan_set_task`
   - claim path가 planning `current_task`를 자동으로 맞추지 않았다면 세션 `current_task`를 claim한 task로 맞춘다.
5. `masc_heartbeat`
   - 긴 작업 전/중에 liveness를 갱신한다.

### 왜 이렇게 하나

- `masc_transition(action="claim") != current_task`
- `masc_claim_next -> current_task` (current builds)
- `join != heartbeat`
- `worktree != namespace`

이 셋을 헷갈리면 dashboard와 실제 workspace collaboration state가 어긋난다.

### 최소 MCP 예시

```json
{
  "tool": "masc_bind",
  "arguments": {
    "agent_name": "agent-code",
    "capabilities": ["ocaml", "dashboard", "documentation"]
  }
}
```

예상 응답 핵심 필드:

```json
{
  "agent": "agent-code-...",
  "status": "joined"
}
```

```json
{
  "tool": "masc_plan_set_task",
  "arguments": {
    "task_id": "task-058"
  }
}
```

예상 상태 변화:

- `masc_plan_get_task`가 `task-058` 반환
- dashboard에서 claimed task와 current_task가 같은 값으로 보임

## Historical Lane 2. Managed Operation / Benchmark Reference

이 경로는 benchmark topology history를 읽기 위한 보조 기록이다. 기본 구현 경로로 취급하지 않는다.

transport truth를 빠르게 분리하고 싶으면 먼저 `./benchmarks/quick-bench.sh` 또는 `./benchmarks/benchmark.sh`를 쓴다.
이 두 스크립트는 반드시 `initialize -> notifications/initialized -> Mcp-Session-Id 재사용` 순서를 포함하고, `mcp_session_init`과 runtime lane을 분리해서 기록한다.
`benchmark.sh`는 warmup 제외와 직전 결과 diff까지 같이 남겨서 before/after 비교용 front door로 쓸 수 있다.

기본 운영 가정:

- `coding_task` stage는 `decompose -> inspect -> implement -> verify -> review`를 canonical graph로 본다.
- Operation/unit/detachment tool variants were removed (no implementation existed).

1. `masc_operator_snapshot` / `masc_operator_digest`
   - operator state와 active recommendation을 읽는다.
2. `masc_operator_action` / `masc_operator_confirm`
   - preview 후 명시 confirm이 필요한 guided action만 처리한다.

### Repo Synthesis

repo-synthesis는 새 front-door tool을 만들지 않고, dashboard proof/report
artifacts를 읽는 방향으로만 유지한다.

- read path:
  - dashboard는 `/api/v1/dashboard/repo-synthesis`와 proof/report artifact를 읽는 read-only surface
- raw escape hatch:
  - 이후 세부 조율은 `masc_operator_digest`와 keeper/runtime surfaces로 내려간다.

### 첫 번째 concrete example: 18+ keeper fleet evidence

가장 먼저 검증할 예시는 research-radar가 아니라 runtime truth가 남은
keeper fleet이다. 예전 `team-session`/public `swarm` proof lane과 compatibility
entrypoint는 retired 되었고, keeper production-readiness gate만 남긴다.

실행 순서:

1. live keeper mutation/probe를 실행해 runtime manifests, receipts,
   checkpoints, memory rows, tool-call logs를 남긴다.
2. repo root에서 아래를 실행한다.

```bash
scripts/harness/workload/agent_swarm_live.sh
```

기본 프로파일:

- 18 keepers
- keeper별 terminal turns >= 3
- keeper별 successful provider turns >= 3
- receipt/checkpoint/provider-closure/memory/tool-log coverage = 100%

성공 기준:

- observed keepers >= 18
- terminal turns >= 54
- successful provider turns >= 54
- per-keeper evidence minimums all satisfied
- missing linked artifacts = 0
- `summary.status = PASS`

확인 위치:

- `logs/keeper_fleet_readiness/<run-id>/summary.json`
- `logs/keeper_fleet_readiness/<run-id>/summary.md`
- direct gate: `scripts/keeper-production-readiness-gate.py --json ...`

### Docker Playground FD Hotspot

macOS Docker Desktop can retain file descriptors for shared files under
`.masc/playground/docker`. When stale keeper repo worktrees accumulate there,
the hotspot can approach `kern.maxfilesperproc` even while MASC's own process
FD count and `/health.status` look healthy.

Inspect the current Docker playground fanout and any host process with open FDs
inside it:

```bash
scripts/docker-playground-fd-status.sh --root "$MASC_BASE_PATH/.masc/playground/docker"
```

MASC does not turn this host-wide observation into a Keeper admission decision.
The macOS system probe reports `kern.num_files`, which is host-wide, not a
per-process Docker Desktop FD count; using it as a hard per-process hotspot
proxy can false-block normal runtime. Keep the script above as the visibility
path and respond to the observed holder/process evidence directly.

The status script prints `Top worktree fanout by keeper/repo` and a
`top_fanout_cleanup_dry_run_command=` for the largest keeper/repo bucket. Use
that targeted dry-run first when `worktree_entries` is high but
`top_holder_fd_count=0`; it separates broad playground pressure from an active
Docker Desktop FD holder spike.

For a broader host check, `scripts/nofile-status.sh` includes this same Docker
playground section when `MASC_BASE_PATH` or `MASC_DOCKER_PLAYGROUND_ROOT` is
set. Its `hotspot_status=warning` output is advisory: review the printed
cleanup dry-run command before removing anything.

If `top_holder_fd_count` remains high after stale worktree cleanup, Docker
Desktop's macOS file sharing layer may still be retaining already-removed
shared-file FDs. In that case the status script prints
`docker_desktop_restart_recommended=true`; verify no critical containers are
running, restart Docker Desktop, then rerun the status check.

Review stale clean worktree candidates first:

```bash
scripts/cleanup-docker-playground-worktrees.sh \
  --root "$MASC_BASE_PATH/.masc/playground/docker" \
  --repo masc \
  --days 7
```

Apply only after reviewing the `CANDID` lines:

```bash
scripts/cleanup-docker-playground-worktrees.sh \
  --root "$MASC_BASE_PATH/.masc/playground/docker" \
  --repo masc \
  --days 7 \
  --apply
```

The cleanup path is conservative: dry-run by default, skips dirty or
runtime-referenced worktrees, removes clean git worktrees through
`git worktree remove`, and leaves branches intact.

If the dry-run reports `BROKEN` entries, review them separately. They are not
removed unless the operator explicitly opts in:

```bash
scripts/cleanup-docker-playground-worktrees.sh \
  --root "$MASC_BASE_PATH/.masc/playground/docker" \
  --repo masc \
  --days 7 \
  --include-broken
```

Then apply with both `--include-broken` and `--apply` only after confirming the
`BROKEN_CANDID` paths are stale orphan directories.

### Local Dune FD Containment

Local OCaml verification must go through the repo wrapper:

```bash
scripts/dune-local.sh build <target>
```

The wrapper serializes local Dune builds across worktrees. Shared server
startup (`start-masc.sh`), local production deploys, and the contract
harness bootstrap also route rebuilds through this wrapper. A direct `dune
build`, `dune test`, `dune exec`, or `dune clean` bypasses that machine-wide
lock and can recreate host-wide FD pressure or mutate `_build` outside the
shared lock even when every cooperative build uses `DUNE_JOBS=1`.

Inspect live pressure and bypasses:

```bash
scripts/nofile-status.sh
```

`potential bare dune bypasses` should be `none`. If a row appears, stop that
process and rerun the command via `scripts/dune-local.sh`. New wrapper
invocations fail fast while a live unwrapped Dune process exists, unless the
operator explicitly sets `MASC_DUNE_ALLOW_BARE_DUNE=1` for a one-off emergency.

When a misbehaving session is repeatedly spawning unwrapped local builds, use an
explicit remediation mode instead of running full `lsof` dumps:

```bash
scripts/nofile-status.sh --kill-bare-dune
scripts/nofile-status.sh --watch 2 --kill-bare-dune --kill-repo-scans
```

The kill flags only target rows already classified by the status script:
unwrapped Dune bypasses and broad `find`/`bfs` scans over `~/me` or `masc`.
Wrapped `scripts/dune-local.sh` builds remain visible but are not terminated.

`orphaned dune-local lock waiters` should also be `none`. A PPID 1 `lockf` or
`flock` row is no longer attached to the agent session that started it; after
confirming it is not the current lock holder, terminate the orphaned waiter so it
does not take the Dune lock later and extend the local build queue.

대표 failure class:

- `keeper_count < expected_keepers`
- `keeper <name> success_provider_turns < min`
- `provider_closure_pct < 100`
- `tool_log_coverage_pct < 100`
- `missing_artifacts > 0`

### 최소 HTTP 예시

Operation/unit/detachment command-plane HTTP endpoints were removed (no tool implementation existed).

## Golden Path 3. Supervised Execution

이건 현재 기본 delivery path다. managed-operation benchmark lane과 분리해서 설명한다.

실제 기능 개발을 `MASC` swarm으로 굴릴 때의 delivery 표준은 별도 문서를 본다:

- ~[SWARM-DELIVERY-RUNBOOK.md](./SWARM-DELIVERY-RUNBOOK.md) (removed)~

1. `masc_operator_snapshot`
2. `masc_operator_digest`
   - namespace/session 상태를 operator-friendly하게 요약한다.
   - current operator context는 board posts, keeper FSM, and dashboard read models에서 읽는다.
3. `masc_operator_action`
4. `masc_operator_confirm`
5. ~`masc_team_session_events` (removed)~

언제 쓰나:

- human/supervisor가 intervention loop를 돌릴 때
- supervised execution session을 guided하게 운영할 때

언제 안 쓰나:

- managed-operation benchmark proof만 필요한 경우
- detachments/policy queue만 따로 검증하려는 경우

## Session Runtime Compat Lane

Removed. `masc_team_session_*` tool family, `team_session_swarm_runner.ml`, and compat harness scripts (`harness_team_session_local64_smoke.sh`, `harness_supervisor_team_session.sh`) were retired. Swarm execution now goes through OAS Swarm Runner directly; workspace collaboration state lives in board posts and keeper FSM.

## Which Tool Now?

- project namespace가 안 잡혔다: `masc_start`
- agent가 roster에 없다: `masc_bind`
- task는 claimed인데 current_task가 없다: `masc_plan_set_task`
- agent가 stale/zombie처럼 보인다: `masc_heartbeat`
- strict action이 멈춰 있다: `masc_operator_snapshot` 후 `masc_operator_confirm`

## 자주 틀리는 포인트

### 1. worktree를 namespace로 착각

증상:
- worktree path로 `masc_start` 했는데 기존 workspace collaboration state가 그대로 보임

정리:
- runtime namespace는 project root 기준 default 하나다
- worktree는 code isolation일 뿐이다

### 2. claim만 하면 current_task가 잡힐 거라 생각

증상:
- task는 claimed
- 그런데 planning/log tools가 task를 못 찾음

정리:
- `masc_transition(action="claim")` 다음에는 `masc_plan_set_task`
- `masc_claim_next`는 current builds에서 auto-bind 되지만, 상태가 비어 있으면 `masc_plan_set_task`로 바로 맞춘다

### 3. heartbeat 없이 오래 작업

증상:
- 실제로는 살아 있는데 stale/zombie처럼 보임

정리:
- long-running step 전/중에 `masc_heartbeat`

### 4. operation start 후 detachment가 안 생김

증상:
- operation은 보이는데 runtime이 없음

정리:
- operation이 아직 시작되지 않았거나
- target unit가 blocked/frozen/approval pending 상태일 수 있음

### 5. worker가 이미 leave 했는데 swarm 화면에서 빠져 보임

정리:
- live presence는 없어도 된다
- completed task ownership + final marker가 기록돼 있으면 joined/task-bound로 복원된다
- 그래서 harness 완료 후 `live_workers`보다 `joined_workers/current_task_bound/final_markers_seen`이 더 중요하다

## 관련 문서

- [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md)
- [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)
- ~[QUICKSTART.md](./QUICKSTART.md) (removed)~
