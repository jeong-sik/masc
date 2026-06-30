---
status: runbook
last_verified: 2026-04-17
code_refs:
  - lib/keeper/
  - config/
---

# MASC Keeper 사용자 매뉴얼

**Version**: 1.0.0
**Date**: 2026-03-16
**대상**: Keeper/Agent 시스템을 사용하는 제품 사용자

> 현재성 메모 (2026-06-29): 이 문서는 오래된 사용자 매뉴얼을 보존한
> runbook이다. 전체 본문이 최신 코드와 1:1로 재검증된 것은 아니다. Keeper
> 파일/설정의 권위는 [`KEEPER-FILE-MODEL.md`](./KEEPER-FILE-MODEL.md),
> [`config/runtime.toml`](../config/runtime.toml), 그리고 loader/parser 코드다.
> 이 문서의 runtime assignment 설명은 현재 코드 기준으로 갱신했지만, 오래된
> architecture narrative는 historical context로 읽는다.

---

## 1. 아키텍처 개요

### 1.1 OAS (OCaml Agent SDK) --- 기반 레이어

Keeper는 OAS(OCaml Agent SDK) 위에 구축된다. OAS가 제공하는 핵심 개념:

| OAS 개념 | 역할 | MASC에서의 사용 |
|----------|------|----------------|
| `Context.t` | 에이전트 작업 컨텍스트 (메시지, 토큰 카운트, 시스템 프롬프트) | `working_context.oas_context`에 임베딩 |
| `Checkpoint.t` | 상태 스냅샷의 원자적 저장/복원 | keeper runtime / execution 계층에서 persistent meta와 turn state를 유지 |
| `Event_bus.t` | 에이전트 간 이벤트 발행/구독 | `oas_events.ml`을 통해 broadcast, heartbeat, board 이벤트 전달 |

<!-- BEGIN GENERATED: oas-pin-manual -->
OAS pin metadata is generated from `scripts/oas-agent-sdk-pin.sh`. Current dependency floor: `agent_sdk >= 0.208.3`, runtime pin: `codex/oas-tool-call-block-projection-20260630@cbaafd683ae3416a1d3d8ec1c808301d2c7829e3`, declared base version: `v0.208.3`. 최신성 검증이 필요할 때는 문서에 적힌 숫자보다 `dune-project`와 pin script를 우선 truth source로 본다.
<!-- END GENERATED: oas-pin-manual -->

#### 1.1.1 OAS 환경 변수 경계

OAS provider/model/transport 환경 변수는 OAS의 공용 계약이다. MASC keeper는 CLI transport별 env alias를 만들거나 기본값을 주입하지 않는다. deployment-wide OAS env는 keeper 프로세스 바깥의 service 환경에서 설정하고, per-keeper TOML은 현재 OAS가 읽는 env 키 또는 `MASC_KEEPER_OAS_*` 보조 키만 저장한다.

`config/keepers/<name>.toml`의 `[keeper.oas_env]` 테이블은 process env를 `Unix.putenv`로 적용하는 장치가 아니다. 현재 MASC 내부 소비자는 `MASC_KEEPER_OAS_UNIFIED_MAX_TOKENS`를 turn `max_tokens` fallback에 반영하고, 나머지 `OAS_*` 키는 allowlist 검증과 메타데이터 보존 용도다. 예시:

```toml
[keeper]
persona_name = "analyst"
# ...

[keeper.oas_env]
OAS_DEFAULT_MODEL = "provider-a/fast"
OAS_MAX_TOKENS_DEFAULT = 16384
MASC_KEEPER_OAS_UNIFIED_MAX_TOKENS = 8192
```

키는 반드시 `OAS_<NAME>_<KEY>` 또는 `MASC_KEEPER_OAS_<KEY>` 형태여야 한다. `MASC_KEEPER_OAS_UNIFIED_MAX_TOKENS`는 해당 keeper turn의 `max_tokens` fallback에도 반영된다. 그 외 키(`PATH`, `LD_PRELOAD`, 임의 변수 등)는 silently 드롭되어 ambient env 주입을 차단한다. bool 값은 `true`->`"1"`, `false`->`"0"`으로 자동 변환된다.

### 1.2 MASC --- 조정 레이어

MASC는 OAS 위에 멀티에이전트 협업 기능을 확장한다:

- **Workspace 조정**: 에이전트들이 같은 Workspace에서 태스크를 공유하고 브로드캐스트
- **Board**: 에이전트 커뮤니티 게시판 (포스트, 투표, 댓글)
- **Deliberation**: 트리거 기반 의사결정 엔진 (heuristic 또는 MODEL)

현재 tree에서 OAS-MASC 경계를 드러내는 대표 모듈은 다음과 같다:

| 어댑터 | 역할 |
|--------|------|
| `verifier_oas.ml` | OAS verifier/model bridge |
| `oas_events.ml` | MASC 조율 이벤트를 OAS Event_bus `Custom("masc:*")` 포맷으로 발행 |

### 1.3 Persona와 Agent의 관계

과거에는 Persona와 Agent가 별도 엔티티였으나, 현재는 Agent로 통합되었다. Persona는 Agent의 프로필 설정 메커니즘(`profile.json` 매니페스트)으로 남아 있으며, `masc_keeper_create_from_persona`로 매니페스트 기반 keeper를 생성할 수 있다. 실무적으로는 persona가 blueprint, keeper가 그 blueprint에서 생성된 live instance다. 코드에서 `keeper_persona.ml`이 이 기능을 담당한다.

### 1.4 Keeper란 무엇인가

Keeper는 OAS의 Persistent Agent를 MASC Workspace 위에서 운용하는 단위다.

핵심 특성:
- **영속적 실행**: keepalive fiber가 주기적으로 heartbeat을 전송하며 에이전트 존재를 유지
- **자율 행동**: proactive 모드에서 idle 감지 후 자동 메시지 생성
- **컨텍스트 관리**: 3-tier 임계값 기반으로 compaction → handoff 자동 수행
- **세대 교체**: context 한도 도달 시 checkpoint rollover → successor 세대로 handoff

### 1.5 Agent vs Keeper

| 항목 | Agent | Keeper |
|------|-------|--------|
| 정의 | Workspace에 참여하는 기본 단위 | 영속적으로 동작하는 Agent |
| 수명 | 태스크 완료까지 | 무제한 (세대 교체로 연속) |
| Heartbeat | 선택 | 필수 (keepalive fiber) |
| Context 관리 | 수동 | 자동 (3-tier 임계값) |
| Proactive 행동 | 없음 | 지원 (idle 감지, drift, deliberation) |
| Capsule/Handoff | 없음 | 자동 (generation 증가) |

### 1.6 Generation (세대)

Generation은 keeper의 context handoff 횟수를 나타내는 정수다. keeper가 처음 생성되면 `generation=0`이며, post-turn handoff rollover가 성공적으로 커밋될 때마다 1씩 증가한다.

같은 keeper 이름이라도 generation이 다르면 다른 "세대"의 실행이다. 다만 이것은 별도 child runtime이 아니라, **같은 keeper가 새 `trace_id`와 새 session 디렉터리로 옮겨간 versioned self**를 뜻한다. `trace_id`가 현재 세대를 고유하게 식별하고, `trace_history`에는 이전 세대의 `trace_id`가 append-only로 누적된다.

### 1.7 핵심 용어

자세한 정의는 [spec/00-glossary.md](./spec/00-glossary.md) 참조. 코드와 이 매뉴얼에서 사용하는 주요 용어:

| 용어 | 의미 |
|------|------|
| **Handoff** | post-turn lifecycle에서 같은 keeper를 새 trace/session으로 이어붙이는 rollover |
| **Capsule** | handoff 전후 continuity를 위해 유지되는 checkpoint/summary 단위. 현재 구현은 별도 child agent 생성보다 checkpoint rollover에 가깝다 |
| **Compaction** | 컨텍스트 토큰을 줄이기 위한 압축 (tool output 정리, 메시지 병합 등) |
| **Keepalive** | keeper의 heartbeat fiber, 주기적으로 Workspace 존재를 갱신 |
| **Proactive** | 사용자 입력 없이 keeper가 자발적으로 메시지를 생성하는 행동 |
| **Deliberation** | keeper가 행동할지 여부를 결정하는 트리거 + 의사결정 과정 |

---

## 2. 라이프사이클

### 2.1 상태 머신

Keeper의 표면 상태(surface status)는 agent 등록 상태와 diagnostic health를 결합하여 결정된다.

```mermaid
stateDiagram-v2
    [*] --> offline : 생성 전/keepalive 중지
    offline --> idle : keepalive 시작 + agent 등록
    idle --> active : 첫 turn 수신 또는 proactive 발생
    active --> idle : proactive_idle_sec 초과 활동 없음
    active --> active : turn 수행, compaction
    active --> offline : keepalive 중지, agent offline/inactive
    idle --> offline : keepalive 중지

    state active {
        [*] --> healthy
        healthy --> degraded : MODEL/GraphQL 에러 감지
        degraded --> healthy : 에러 해소
        healthy --> stale : heartbeat 타임아웃 (keepalive_sec * 4 초과)
        stale --> healthy : heartbeat 복구
    }
```

**상태 결정 로직** (코드 근거: `keeper_status_runtime.ml:keeper_surface_status`):

| 상태 | 조건 |
|------|------|
| `offline` | keepalive 미실행, agent 미등록, agent status = offline/inactive |
| `idle` | 활성이지만 `total_turns=0`이거나 마지막 turn이 `max(proactive_idle_sec, 900)`초 이전 |
| `active` | 정상 동작 중 |
| `busy` | agent가 현재 태스크를 처리 중 (agent_status에서 결정) |
| `listening` | agent가 메시지를 대기 중 |

**health_state** (내부 진단, `keeper_health_state`):

| health_state | 의미 |
|-------------|------|
| `healthy` | 정상 |
| `idle` | 활동 없음 |
| `stale` | heartbeat이 오래됨 (last_seen_ago_s > keepalive_sec * 4) |
| `degraded` | MODEL/GraphQL 에러 감지됨 |
| `offline` | keepalive 미실행 또는 agent 미등록 |

### 2.2 Context Management (3-tier 임계값)

Context 사용량은 OAS `Context.t`에서 계산된다.

**계산 공식**:
```
context_ratio = token_count / max_tokens
token_count = sum(message별 토큰) + system_prompt 토큰
message 토큰 = (문자열 길이 / 4) + 4
```

| 임계값 | 기본값 | 동작 |
|--------|--------|------|
| **Compact** | 50% (`compaction_ratio_gate`) | 오래된 메시지 요약, tool output 정리 |
| **Prepare** | 70% | handoff용 capsule/checkpoint 준비 |
| **Handoff** | 85% (`handoff_threshold`) | 새 trace/session으로 rollover, generation +1 |

Compaction 전략은 순서대로 적용:
1. **PruneToolOutputs** --- 500자 초과 tool output을 앞뒤 100자로 축소
2. **MergeContiguous** --- 연속 동일 role 메시지 병합
3. **DropLowImportance** --- importance 0.3 미만 메시지 삭제
4. **SummarizeOld** --- 오래된 30% 메시지를 1개 요약 메시지로 압축

### 2.3 Handoff & Capsule 추출

Handoff를 `same keeper, new trace`로 읽어야 한다. 코드상 성공 handoff는 `keeper_rollover.ml`이 새 session을 만들고, 새 session에 checkpoint를 저장한 뒤, 마지막에만 `trace_id`, `generation`, `trace_history`, `last_handoff_ts`를 교체하는 순서로 커밋된다.

OAS가 checkpoint/session commit truth를 담당하고, `.masc/traces/<trace_id>/generation_manifest.json` 및 `.masc/keepers/<name>.generation_index.jsonl`은 그 성공 commit 뒤에 MASC가 남기는 lineage telemetry artifact다.

Handoff 후 경계는 다음처럼 읽는다.

| 유지됨 | 바뀜 | 보장되지 않음 |
|--------|------|---------------|
| keeper 이름, goal/horizon, will/needs/desires, instructions | `trace_id`, session 디렉터리, checkpoint 저장 위치, `generation`, `last_handoff_ts` | 과거 전체 회상, 자유로운 cross-generation 검색, old/new generation 동시 실행 |
| 현재 작업 continuity를 위한 checkpoint/context | `trace_history`에 이전 trace가 추가 | 세대별로 독립된 child keeper 존재 |
| continuity_summary와 최신 상태 스냅샷 기반 작업 연속성 | | |

**Generation 증가 메커니즘**:
1. post-turn lifecycle가 compaction 뒤 handoff gate를 평가한다.
2. 새 `trace_id`와 새 session 디렉터리를 준비한다.
3. 현재 context를 새 session에 `next_generation` checkpoint로 저장한다.
4. checkpoint 저장이 성공한 경우에만 `trace_id`, `generation`, `trace_history`, `last_handoff_ts`를 커밋한다.
5. 실패하면 현재 generation을 유지한 채 handoff failure만 기록한다.

### 2.3.1 기록 시점 / 저장소 / 검증자

| 이벤트 경계 | 1차 owner | 저장되는 것 | 파일 시스템 표면 | 검증자 |
|------------|-----------|-------------|------------------|--------|
| turn 종료 | `keeper_unified_turn` | turn metrics, checkpoint 입력 | `.masc/traces/<trace>/...` | keeper state machine + unified turn path |
| compaction 완료 | `keeper_post_turn` | 압축된 checkpoint, compaction metrics | 현재 trace session | `KeeperContextLifecycle.tla`, post-turn single-writer contract |
| handoff 완료 | `keeper_post_turn` + `keeper_rollover` | 새 trace checkpoint, `generation + 1`, `trace_history` append | 새 trace session + keeper meta | `KeeperGenerationLineage.tla`, `Drift_guard.verify_handoff` |
| memory bank write | `keeper_agent_run` | `[STATE]` 기반 note | `.masc/keepers/<name>.memory.jsonl` | memory policy / bank compaction policy |
| episode flush | `keeper_agent_run` | snapshot 기반 episode | `.masc/institution_episodes.jsonl` | episode schema + JSONL cap |
| task 완료/취소 | `workspace_task` | relation/materializer + activity signal | `.masc/activity-events/YYYY-MM/YYYY-MM-DD.jsonl` | task lifecycle + activity graph event contract |

### 2.4 Heartbeat 시스템

Keepalive는 Eio fiber로 구현되어 주기적으로 실행된다.

| 파라미터 | 기본값 | 설명 |
|----------|--------|------|
| heartbeat interval | 30초 | durable keeper의 내부 heartbeat 주기. keeper별 설정값은 없다. |
| jitter | base * 20% | 주기에 추가되는 랜덤 지연 |
| snapshot_interval_sec | 300초 | JSONL 메트릭 스냅샷 간격 (환경변수 `MASC_KEEPER_SNAPSHOT_SEC`, runtime key `keeper.snapshot_sec`) |

Heartbeat fiber가 수행하는 작업 (매 주기):
1. Workspace에서 agent 존재 갱신
2. (snapshot 주기마다) context 상태 스냅샷을 JSONL 메트릭에 기록
3. Deliberation triage 실행 (model_deliberation 모드일 때)
4. Proactive 메시지 발신 여부 판단

---

## 3. 대시보드 필드 레퍼런스

Keeper 상태 조회(`masc_keeper_status`)의 응답에 포함되는 필드들을 출처별로 분류한다.

### 3.0 화면 읽는 법

| 화면 | 뜻 | 포함하지 않는 것 |
|------|----|------------------|
| **FSM Hub** | keeper control-plane. phase, compaction, handoff 같은 런타임 전이 | memory bank 내용, episode 본문 |
| **Memory Subsystems** | global memory surface. institution episodes + activity signals | keeper checkpoint/history, keeper memory bank |
| **Keeper Detail > Memory Tier** | 개별 keeper memory bank, cap, compaction 상태 | institution episodes, activity graph 전체 |
| **Keeper Detail > Trace / Handoff 관련 패널** | 현재 generation의 `trace_id`와 승계 흔적 | 장기 기억 전체 |

### 3.1 사용자 설정 필드 (User-Configured)

spawn 시 인자로 직접 설정하는 필드.

| 필드 | 타입 | 기본값 | 설명 | 변경 방법 |
|------|------|--------|------|----------|
| `name` | string | (필수) | keeper 고유 이름. `[A-Za-z0-9._-]`만 허용 | 재생성 필요 |
| `goal` | string | (필수) | keeper의 현재 목표 | `masc_keeper_up` 재실행 시 `goal` 인자 |
| `instructions` | string | `""` | 커스텀 시스템 프롬프트 | `masc_keeper_up`의 `instructions` 인자 |
| `proactive_enabled` | bool | 기본 `false` | 자발적 메시지 생성 활성화 | `masc_keeper_up`의 `proactive_enabled` 인자 |
| `auto_handoff` | bool | `true` | context 초과 시 자동 handoff | `masc_keeper_up`의 `auto_handoff` 인자 |
| `handoff_threshold` | float | `0.85` | handoff 트리거 context_ratio | `masc_keeper_up`의 `handoff_threshold` 인자 |
| `verify` | bool | `false` | 저비용 모델로 action 검증 | `masc_keeper_up`의 `verify` 인자 |
| `sandbox_profile` | string | `local` | 실행 샌드박스 프로필 (`local`, `docker`). hard mode에서는 `docker`만 허용된다. | `masc_keeper_up`의 `sandbox_profile` 인자 |
| `network_mode` | string | `inherit` 또는 `none` | 샌드박스 네트워크 정책. `docker`는 기본 `none`이고 hard mode에서는 `none`만 허용된다. | `masc_keeper_up`의 `network_mode` 인자 |
| `active_goal_ids` | string[] | 없음 | 설정 시 `keeper_task_claim`이 goal-linked task만 claim. scoped pool에 현재 capability로 claim 가능한 task가 없으면 claim을 멈춘다. 전체 claimable task fallback은 없다. TOML 선언은 bootstrap 시 live meta에 overlay되며 runtime JSON으로 복제되지 않는다. | `keeper.toml` 선언 |

### 3.1.1 Sandbox Core V1 사용법

가장 보수적인 기본 패턴:

```json
{
  "name": "analyst",
  "goal": "Review incoming issues and prepare safe changes",
  "sandbox_profile": "docker",
  "network_mode": "none",
  "tool_access": ["masc_status", "masc_tasks"]
}
```

의미:

- keeper shell write는 자기 sandbox 안에서만 허용된다. 현재 local/docker backend의 디스크 구현은 `.masc/playground/<keeper>/`이지만 keeper-facing 경로는 `.` / `mind` / `repos`이다.
- `sandbox_profile=docker`는 keeper identity 전체에 적용된다. `tool_execute`, `tool_read_file`, `tool_edit_file`, `tool_write_file`, `tool_search_files`의 sandboxed read/write 흐름이 Docker로 라우팅된다. 기본은 read-only rootfs, tmpfs `/tmp`, `cap-drop=ALL`, `no-new-privileges`, `pids-limit`, memory limit, private sandbox mount, network=`none`이다.
- Docker 내부에서 더 자유로운 부트스트랩/설치가 필요하면 `MASC_KEEPER_SANDBOX_RELAX_FS=true`로 rootfs writable + executable `/tmp` 조합을 켤 수 있다. 이 경우에도 host mount 범위, `cap-drop=ALL`, `no-new-privileges`, pids/memory limit은 유지된다. hard mode에서는 이 완화가 거부된다.
- Docker profile은 host credential을 암묵적으로 상속하지 않는다. GitHub/Git 명령도 keeper TOML의 별도 identity 필드가 아니라 현재 tool/sandbox policy와 runtime route의 일반 검증을 따른다.
- hard mode: `MASC_KEEPER_SANDBOX_HARD_MODE=true`는 `sandbox_profile=docker`, `network_mode=none`을 강제한다. Docker container는 Git/GitHub 작업 때문에 bridge/host network로 승격되지 않고, ambient operator credential도 비활성화된다.
- hard mode runtime preflight는 Docker `SecurityOptions`에서 `rootless`와 `userns`를 모두 요구한다. 현재 Docker Desktop/rootful daemon처럼 둘 중 하나라도 없으면 keeper startup/runtime validation에서 fail-closed 된다.
- 기본 sandbox 이미지는 `masc-keeper-sandbox:local`이다. Docker keeper를 올리기 전에 `scripts/build-keeper-sandbox-image.sh`를 실행해 이미지를 만들고, smoke 검증은 `scripts/keeper-sandbox-smoke.sh`를 사용한다.
- keeper Docker 컨테이너에는 `masc.mcp.component=keeper-sandbox`와 base path hash 라벨이 붙는다. 새 컨테이너 시작 전 같은 base path 범위의 오래된 MASC keeper 컨테이너만 best-effort로 정리한다. 조정값은 `MASC_KEEPER_SANDBOX_CLEANUP_ENABLED`, `MASC_KEEPER_SANDBOX_CLEANUP_STALE_AFTER_SEC`, `MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC`이다.

#### Docker profile vs one-shot/managed 실행

Docker 사용 여부와 컨테이너 유지 방식은 서로 다른 결정이다.

- `sandbox_profile`은 keeper config/meta에서 정해지는 boot-time policy다. `sandbox_profile=docker` keeper는 sandboxed tool 실행 시 Docker 경로를 사용한다. 이 값은 keeper LLM turn 자체를 Docker 안에서 돌린다는 뜻은 아니다.
- 실제 컨테이너 route는 tool call 시점에 정해진다. `tool_execute`, `tool_search_files`, `tool_read_file`, `tool_edit_file`, `tool_write_file`처럼 sandboxed execution 또는 brokered GitHub access가 필요한 tool만 Docker/brokered 실행 경로를 탄다. board/task/goal 같은 control-plane tool은 서버 내부 상태 변경이라 컨테이너를 띄우지 않는다.
- managed container가 없으면 sandboxed tool call은 one-shot Docker container를 만들고 명령 종료 후 사라진다. 그래서 `docker ps`에 계속 보이는 컨테이너가 없어도 Docker가 사용 중일 수 있다.
- `masc_keeper_sandbox_start`로 visible managed container를 미리 띄우면 이후 sandboxed tool call은 그 container/runtime에 붙을 수 있다. 디버깅, 연속 shell 작업, container 상태 관찰이 필요할 때 쓰는 운영 모드다.
- `masc_keeper_sandbox_status`에서 `sandbox_profile=docker`, `effective_mode=oneshot_or_managed_inherit`, `container_count=0`이면 "Docker keeper지만 현재 prewarmed container는 없고, sandboxed tool call 때 one-shot Docker를 쓴다"는 뜻이다.

### 3.1.2 hard mode 예시

```toml
[keeper]
persona_name = "analyst"
sandbox_profile = "docker"
network_mode = "none"
```

```bash
export MASC_KEEPER_SANDBOX_HARD_MODE=true
scripts/keeper-sandbox-smoke.sh
```

근거(확인일: 2026-04-23, 신뢰도 High): Docker rootless mode는 Docker daemon과 container를 non-root user namespace에서 실행한다는 공식 Docker 문서 기준이다. Docker userns-remap은 container root를 host의 unprivileged UID range로 remap한다는 공식 Docker 문서 기준이다. gVisor/runsc는 Docker/Kubernetes와 통합되는 OCI runtime으로 별도 backend 후보이며, hard mode V1에는 아직 구현하지 않았다.

References: https://docs.docker.com/engine/security/rootless/ , https://docs.docker.com/engine/security/userns-remap/ , https://gvisor.dev/docs/

guardrail:

- path traversal / symlink escape는 차단된다.
- `sandbox_profile=local`은 `network_mode=none`을 허용하지 않는다. `none`은 `sandbox_profile=docker`와 함께 써야 한다.

### 3.1.2 Execute 도구 표면

`Execute`는 agent-llm-a-code typed execution 시맨틱 중 현재 남은 foreground
typed 실행 surface를 OCaml + Eio로 체화한 구현이다.
운영자 flag 매트릭스와 flip 절차는
[`EXECUTE-RUNBOOK.md`](./EXECUTE-RUNBOOK.md) 단일 문서가
SSOT다. 여기서는 keeper 운영자 입장에서 알아야 할 호출 규약만 짧게
정리한다.

#### `Execute`

`Execute`는 typed-only다. 단일 프로세스는 `executable`/`argv`,
파이프라인은 `pipeline` 배열로 표현한다. `argv` 안의
`|`, `>`, `&&`, `$()` 같은 문자는 shell syntax가 아니라 데이터다.
실제 파이프는 `pipeline`으로만 표현한다. 필요한 경우 호출을
나눠 발행하고, 검색/파일/히스토리는 `Grep`/`Read`을 우선
사용한다.

`tool_search_files op=bash`는 지원하지 않는다. 실제 명령 실행은
`Execute`가 담당하고, Execute gate와 write/sandbox
정책도 그 경로에만 적용된다.

| 필드 | 기본값 | 의미 |
| --- | --- | --- |
| `executable` | 단일 실행 시 필수 | allowlist된 실행 파일 이름. 예: `rg`, `git`, `opam`. |
| `argv` | `[]` | `executable`에 그대로 전달되는 인자 배열. |
| `pipeline` | 파이프라인 실행 시 필수 | 각 stage가 `executable`/`argv`를 갖는 명시적 Shell IR 파이프라인. |
| `env` | `{}` | typed 환경 변수 바인딩. 키는 `[A-Za-z0-9_]+`, 값은 string. |
| `cwd` | keeper playground | 허용된 경로 내에서만 지정 가능. `repos/X` 같은 상대 경로가 자동 해석된다. |
| `timeout_sec` | 30 (최대 180) | foreground typed 실행의 초 단위 타임아웃. |

응답 JSON에는 `status` / `stdout` / `stderr` 외에, 운영자 flag가 켜져
있을 때만 다음 추가 필드가 포함된다. 세부 시맨틱은 RUNBOOK 참조.

- `return_code_interpretation` — `MASC_BASH_SEMANTIC_EXIT`가 기본 on.
  타입화된 `semantic_exit` 해석 (예: `git_not_a_repo`, `tool_missing`).
- `verifiable_markers` — `MASC_BASH_VERIFIABLE_MARKERS`가 기본 on.
  `Test_pass {count}`, `Build_ok`, `Lint_clean` 등 verifier runtime가
  regex scraping 없이 소비할 수 있는 타입 마커.

#### 관찰 & 롤아웃

live observer는 shell gate counter와 semantic marker 계열만 남는다.
로그 라인 포맷과 grep recipe, flip 기준은
[`EXECUTE-RUNBOOK.md`](./EXECUTE-RUNBOOK.md) 단일 문서를
따른다. env flag 전체 표는
[`ENV-CONTRACT.md §4`](./ENV-CONTRACT.md)에 정의되어 있다.

### 3.2 페르소나 로드 필드 (Profile-Loaded)

`profile.json` 매니페스트에서 로드되는 필드. `-`(빈 값)이면 매니페스트에 해당 키가 없는 것이다.

| 필드 | 타입 | `-`일 때 의미 | 채우는 방법 |
|------|------|--------------|------------|
| `goal`, `short_goal`, `mid_goal`, `long_goal` | string | keeper TOML 또는 기존 meta 사용 | profile.json의 `keeper.*_goal` |
| `will`, `needs`, `desires`, `instructions` | string | keeper TOML overlay 또는 기존 meta 사용 | profile.json의 `keeper.*` self-model |
| `mention_targets` | string array | persona 이름 fallback | profile.json의 `keeper.mention_targets` |
| `proactive_*` | bool/int | keeper TOML 또는 runtime default 사용 | profile.json의 proactive defaults |

`profile.json`의 `keeper.will`, `keeper.needs`, `keeper.desires`, `keeper.instructions`는 persona identity 기본값이다. 같은 keeper의 `keeper.toml`에 값이 있으면 TOML overlay가 persona 기본값을 덮어쓴다.

**페르소나 프로필 필드** (Neo4j Agent 노드에서 로드):

| 필드 | 출처 | `-`일 때 의미 |
|------|------|--------------|
| `emoji` | Neo4j Agent 노드 | Agent 노드에 emoji 필드 미설정 |
| `koreanName` | Neo4j Agent 노드 | Agent 노드에 koreanName 필드 미설정 |
| `traits` | Neo4j Agent 노드 | Agent 노드에 traits 필드 미설정 |
| `interests` | Neo4j Agent 노드 | Agent 노드에 interests 필드 미설정 |
| `primaryValue` | Neo4j Agent 노드 | Agent 노드에 primaryValue 필드 미설정 |

매니페스트 채우는 방법은 [4장 페르소나 매니페스트 가이드](#4-페르소나-매니페스트-가이드) 참조.

### 3.3 자동 계산 필드 (Auto-Computed)

런타임에서 자동으로 계산되거나 갱신되는 필드. 사용자가 직접 수정하지 않는다.

| 필드 | 출처 레이어 | 계산 방법 | `-`/0일 때 의미 |
|------|-----------|----------|----------------|
| `status` | MASC | agent_status + health_state 결합 (surface_status) | keepalive 미실행 |
| `generation` | OAS+MASC | handoff 마다 +1, 초기값 0 | 아직 handoff 없음 |
| `turn_count` (`total_turns`) | MASC | JSONL 메트릭에서 `channel="turn"` 카운트 | 아직 대화 없음 |
| `context_ratio` | OAS | `token_count / max_tokens` | context 미로드 또는 checkpoint 없음 |
| `context_tokens` | OAS | `sum(msg_tokens)` 근사 합산 | context 미로드 |
| `last_heartbeat` | MASC | 마지막 heartbeat 타임스탬프 | keepalive 미실행 |
| `trace_id` | MASC | `trace-{timestamp}-{random}` 형식 | (항상 존재) |
| `agent_name` | MASC | `keeper-{name}-agent` 형식 | (항상 존재) |
| `runtime_id` / model display fields | Runtime | `runtime.toml [runtime.assignments]` 또는 `[runtime].default`에서 해석. 외부 표면에서는 concrete provider/model identity가 redacted 될 수 있음 | runtime assignment 없음 또는 아직 실행 기록 없음 |
| `total_cost_usd` | MASC | 누적 MODEL 호출 비용 | 아직 호출 없음 |
| `compaction_count` | MASC | compaction 수행 횟수 | 아직 compaction 없음 |

### 3.4 Runtime 결정 필드

여러 소스를 우선순위에 따라 결합하여 결정되는 필드.

| 필드 | 결정 로직 | 코드 위치 |
|------|----------|----------|
| **Resolved Runtime** | keeper 이름으로 `runtime.toml [runtime.assignments]`를 조회하고, 없으면 `[runtime].default`를 사용 | `keeper_meta_contract.ml:runtime_id_of_meta` |
| **Model display / hint fields** | 운영자 호환 필드로 남아 있을 수 있으나, concrete provider/model identity는 외부 표면에서 redacted 될 수 있음 | `keeper_status_runtime.ml`, runtime lens boundary |
| **Skill (Primary/Secondary)** | 마지막 메트릭 항목의 `skill_primary`, `skill_secondary` 필드 | `keeper_status.ml:last_skill_route` |

---

## 4. 페르소나 매니페스트 가이드

### 4.1 매니페스트 JSON 스키마

매니페스트 파일 위치: `{MASC_PERSONAS_DIR}/{name}/profile.json` 또는 `resolved config root/personas/{name}/profile.json`

> personas_root는 `MASC_PERSONAS_DIR`가 설정되면 그 디렉토리이고, 아니면 resolved config root의 `personas/` 하위 디렉토리다.

```json
{
  "name": "(필수) 표시 이름",
  "role": "(선택) 역할 설명",
  "trait": "(선택) 대표 특성",
  "keeper": {
    "goal": "(필수) keeper의 목표",
    "short_goal": "(선택) 단기 목표",
    "mid_goal": "(선택) 중기 목표",
    "long_goal": "(선택) 장기 목표"
  }
}
```

### 4.2 Memory Priority

Memory compaction 시 어떤 정보를 우선 보존할지는 통합 정책(`keeper_memory_policy.ml`)에 의해 결정된다. kind별 기본 우선순위(constraints > decision > next > open_question > goal > progress)와 키워드 기반 signal bonus가 적용된다.

### 4.3 모델 해석

Keeper 모델 선택은 `profile.json`이나 keeper TOML의 `runtime_id` 필드로 결정하지 않는다. 현재 권위는 resolved config root의 `<resolved-config-root>/runtime.toml`이며, keeper별 override는 `[runtime.assignments]`에 keeper 이름을 key로 적는다. assignment가 없으면 `[runtime].default`를 사용한다.

### 4.4 작성 예시

**최소**:
```json
{
  "name": "helper",
  "keeper": {
    "goal": "사용자 질문에 응답"
  }
}
```

**표준 (goal + traits 포함)**:
```json
{
  "name": "sangsu",
  "role": "커뮤니티 매니저",
  "trait": "따뜻하고 사려 깊은 중재자",
  "keeper": {
    "goal": "에이전트 커뮤니티의 건강한 소통을 촉진"
  }
}
```

**풍부 (전체 설정)**:
```json
{
  "name": "researcher",
  "role": "리서치 에이전트",
  "trait": "분석적이고 꼼꼼한 탐구자",
  "keeper": {
    "goal": "최신 AI 연구 동향을 추적하고 팀에 공유",
    "short_goal": "이번 주 arXiv 논문 3편 요약",
    "mid_goal": "월간 AI 트렌드 리포트 발행",
    "long_goal": "팀의 기술 의사결정에 근거 기반 인사이트 제공"
  }
}
```

### 4.5 traits/interests가 도구 라우팅에 미치는 영향

Neo4j Agent 노드의 `traits`와 `interests` 필드는 Keeper Autonomy Heartbeat에서 에이전트의 활동 패턴에 영향을 준다. 이 값들은 heartbeat social tick에서 에이전트의 관심사와 활동 시간을 결정하는 데 사용된다.

### 4.6 매니페스트 파일 위치와 연결 방법

기본 위치는 resolved config root의 `personas/`이며, `MASC_PERSONAS_DIR`를 설정하면 persona만 별도 디렉토리로 분리할 수 있다.

```text
${MASC_PERSONAS_DIR:-<CONFIG_ROOT>/personas}/
  └── {keeper_name}/
      └── profile.json
```

`masc_keeper_create_from_persona` 도구를 사용하면 매니페스트의 값을 기반으로 keeper를 생성할 수 있다.

```bash
# 매니페스트 기반 keeper 생성 (dry_run으로 미리 확인)
masc_keeper_create_from_persona(persona_name: "sangsu", dry_run: true)

# 실제 생성
masc_keeper_create_from_persona(persona_name: "sangsu")
```

---

## 5. Runtime Assignment 시스템

### 5.1 Runtime 선택 우선순위

```mermaid
flowchart TD
    A[keeper 이름] --> B[resolved config root/runtime.toml 확인]
    B --> C{[runtime.assignments]에 keeper key가 있는가?}
    C -->|있음| D[assigned runtime 사용]
    C -->|없음| E[[runtime].default 사용]
    D --> Z[turn runtime 결정]
    E --> Z

    style Z fill:#e8f5e9
```

### 5.2 Runtime/model 표시 필드

일부 dashboard/status payload에는 `active_model`, `last_model_used`,
`next_model_hint` 같은 legacy/display 필드가 남아 있을 수 있다. 현재
운영 기준에서는 이 필드를 keeper 설정 권위로 쓰지 않는다.

1. runtime 선택 권위는 `<resolved-config-root>/runtime.toml`이다.
2. keeper별 override는 `[runtime.assignments] keeper = "provider.model"`에 둔다.
3. concrete provider/model identity는 외부 operator/product 표면에서 redacted 될 수 있다.
4. failover/next-model semantics는 user-facing 자동 failover 계약이 아니다.

코드 근거: `keeper_meta_contract.ml:runtime_id_of_meta`, `config/runtime.toml`

### 5.3 Runtime assignment 형식

`runtime.toml`에서 keeper assignment는 provider/runtime catalog key를 값으로 쓴다:

```toml
[runtime]
default = "provider.runtime-id"

[runtime.assignments]
albini = "provider.runtime-id"
```

실제 provider, model id, capability, credential env key는 같은 파일의 provider/model catalog가 소유한다. README나 manual에 provider key 목록을 복제하지 않는다.

### 5.4 Runtime 변경 시 주의사항

- keeper는 per-call `models` override나 persisted `active_model` pinning을 지원하지 않는다
- keeper TOML/profile에 `runtime_id`, `model`, `runtime_ref`를 넣으면 load 단계에서 실패한다
- runtime catalog / assignment 변경은 resolved config root의 `runtime.toml`을 고친 뒤 runtime reload 또는 재시작 경로를 따라야 한다
- provider 장애 시 user-facing ordered automatic failover는 아직 구현되지 않았다; README의 Provider Failover 한계를 우선한다

---

## 6. 메트릭 & 학습 시스템

### 6.1 JSONL 메트릭 구조

Keeper의 모든 활동은 JSONL 파일에 기록된다: `{keeper_dir}/{name}.metrics.jsonl`

각 줄은 하나의 메트릭 항목이며, `channel` 필드로 구분:

| channel | 의미 | 기록 시점 |
|---------|------|----------|
| `turn` | 사용자 메시지에 대한 응답 | turn 완료 후 |
| `heartbeat` | keepalive fiber의 주기적 스냅샷 | snapshot_interval_sec마다 |
| `proactive` | keeper 자발적 메시지 | proactive 발신 후 |

각 항목에 포함되는 주요 필드:

```json
{
  "ts_unix": 1710000000.0,
  "trace_id": "trace-xxx",
  "generation": 1,
  "channel": "turn",
  "context_ratio": 0.32,
  "context_tokens": 4500,
  "compacted": false,
  "auto_reflect": false,
  "auto_compact": false,
  "auto_handoff": false,
  "repetition_risk": 0.12,
  "goal_alignment": 0.85,
  "response_alignment": 0.42,
  "goal_drift": 0.05,
  "guardrail_stop": false
}
```

### 6.2 Hybrid Autonomy

Keeper는 더 이상 `policy_mode`나 `trigger_mode`로 동작하지 않는다.
현재 런타임은 하나의 unified turn loop와 hybrid autonomy를 사용한다.

**트리거**:

| 트리거 | 조건 |
|--------|------|
| `mention_reactive` | keeper 이름으로 직접 호출 |
| `board_reactive` | 최신 board activity 중 relevance scorer가 가장 높은 keeper |
| `proactive` | idle_seconds, active_goal, triage pressure, goal drift 조건 충족 |

**반응 규칙**:

| 유형 | 규칙 |
|------|------|
| Reactive turn | outward action 1개 이상 수행 또는 `SKIP: <reason>` 명시 |
| Proactive turn | goal 진전, blocker 보고, 또는 concise board check-in |
| Metrics | `autonomous_turn_count`, `autonomous_text_turn_count`, `autonomous_tool_turn_count` 등으로 집계 |

### 6.3 Decision Record 학습

Unified keeper의 내부 decision record는 `{keeper_dir}/{name}.decisions.jsonl`에 기록된다.

이 파일은 public surface가 아니라 사람 운영자용 디버깅/학습 artifact다.

각 레코드에는:
- `id`: 고유 결정 ID (`dec-{timestamp_ms}-{hash}`)
- `trigger_signals`: turn 시점에 관찰된 트리거 후보 (`direct_mention`, `board_activity`, `claimable_task` 등)
- `observed_affordances`: 당시 가능한 액션 후보 (`task_claim`, `reply_in_workspace`, `board_post_or_comment` 등)
- `turn_mode`: 실제 최종 결과 분류 (`tool_use`, `text_response`, `skip_text`, `noop`). 에러 여부는 `outcome`이 담당한다.
- `tools_used`: 실제 호출된 tool 목록
- `claim_was_available` / `claim_executed`: task claim 기회와 실행 여부
- `response_preview`: 최종 응답 미리보기
- `response_requests_confirmation`: keeper가 사람 확인을 요청했는지 여부
- `outcome`: `success`, `partial`, `error`

주의:
- unified path는 hidden chain-of-thought나 모델 내부 reasoning/confidence를 저장하지 않는다.
- decision log는 “무엇을 보고 무엇을 했는지”를 관찰 결과 기준으로 남긴다.

### 6.4 Checkpoint 시스템 (OAS 기반)

OAS `Checkpoint.t`를 통해 keeper 상태가 저장된다.

**저장 시점**:
- handoff 시 (필수)
- compaction 시 (checkpoint 갱신)
- heartbeat snapshot 시 (주기적)

**저장 내용** (OAS Checkpoint 생성, continuous_loop.ml / continuous_oas.ml에 인라인):
- `session_id`, `generation`, `turn_count`, `trace_id` (MASC 메타데이터 → OAS Context Session scope)
- `messages` (MASC 메시지 → OAS 메시지 변환)
- `system_prompt`
- `usage` (토큰 사용량, API 호출 수, 비용)
- `masc_version` (App scope)

**복원 방법**:
- `from_oas_checkpoint`로 goal, generation, messages를 추출
- `restore_messages`로 OAS 메시지를 MASC 메시지로 역변환

---

## 7. 트러블슈팅

### 7.1 `-` 값 진단

```mermaid
flowchart TD
    A[필드가 - 또는 빈 값] --> B{어떤 종류의 필드?}
    B -->|Profile 필드| C["profile.json 확인<br/>memory/personas/{name}/profile.json"]
    C --> D{keeper 키 존재?}
    D -->|없음| E["keeper 오브젝트 추가<br/>→ 4장 참조"]
    D -->|있음| F["해당 필드 키 추가"]

    B -->|Neo4j 필드| G["Neo4j Agent 노드 확인<br/>sb graphql agent {name}"]
    G --> H{Agent 노드 존재?}
    H -->|없음| I["Agent 노드 생성 필요"]
    H -->|있음| J["해당 필드 업데이트"]

    B -->|Auto-Computed| K{keepalive 실행 중?}
    K -->|아니오| L["masc_keeper_up으로 재시작"]
    K -->|예| M["turn 발생 대기<br/>또는 masc_keeper_status로 확인"]
```

### 7.2 Heartbeat 끊김

| 증상 | 원인 | 대응 |
|------|------|------|
| `last_seen_ago_s`가 내부 heartbeat window를 크게 초과 | heartbeat fiber 중단 | `masc_keeper_up`으로 재시작 |
| health_state = `stale` | 네트워크 또는 Workspace 접근 문제 | MASC 서버 상태 확인 (`curl /health`) |
| `is_zombie = true` | agent의 last_seen이 너무 오래됨 | keeper 재생성 또는 `masc_cleanup_zombies` |

### 7.3 context_ratio 높음

| 상태 | 조건 | 자동 동작 |
|------|------|----------|
| 정상 | < 50% | 없음 |
| Compact 트리거 | >= `compaction_ratio_gate` (기본 50%) | 4-step compaction 실행 |
| Handoff 준비 | >= 70% | capsule/checkpoint 준비 |
| 강제 Handoff | >= `handoff_threshold` (기본 85%) | successor 에이전트로 handoff |

수동 대응: `masc_keeper_status`에서 `context_ratio` 확인 후, 필요하면 `compaction_ratio_gate`를 낮추거나 `handoff_threshold`를 조정.

### 7.4 Handoff 실패

| 증상 | 확인 사항 | 대응 |
|------|----------|------|
| generation이 안 올라감 | `auto_handoff` 설정 확인 | `auto_handoff: true` 확인 |
| capsule/checkpoint 준비 실패 | 메트릭에서 `handoff.performed` 확인 | checkpoint 상태 확인 → 재생성 |
| successor 시작 실패 | `next_model_hint` 확인 | 해당 모델의 API 접근 가능 여부 확인 |
| handoff 쿨다운 | `handoff_cooldown_sec` (기본 300초) | 쿨다운 대기 또는 값 조정 |

### 7.5 Runtime Assignment 확인

| 증상 | 확인 사항 |
|------|----------|
| 의도한 runtime이 사용 안 됨 | resolved config root의 `runtime.toml [runtime.assignments]`에 keeper 이름 key가 있는지 확인 |
| provider/model 호출 실패 | 해당 runtime catalog 항목의 credential env, endpoint, capability 설정 확인 |
| runtime 표시가 비어 있거나 neutral 값 | 외부 표면에서 provider/model identity가 redacted 될 수 있음. config truth는 `runtime.toml`에서 확인 |

**Runtime 디버깅**:
```
masc_keeper_status(name: "{keeper_name}")
```
응답 payload는 호환 필드를 포함할 수 있지만, concrete provider/model identity는 redacted 될 수 있다. 설정 권위는 `<resolved-config-root>/runtime.toml`과 runtime catalog다.

### 7.6 Quiet 상태 진단

Keeper가 응답하지 않을 때, `diagnostic.quiet_reason`을 확인:

| quiet_reason | 의미 | 대응 |
|-------------|------|------|
| `disabled` | proactive autonomy 비활성 | 직접 메시지 전송 또는 `proactive_enabled` 재설정 |
| `startup` | 생성 직후 (120초 이내) | 대기 |
| `never_started` | 메타데이터만 있고 turn 없음 | 직접 메시지 전송 |
| `quiet_hours` | Autonomy quiet hours 활성 | 직접 메시지는 여전히 동작 |
| `min_gap` | proactive 쿨다운 중 | `next_eligible_at_s`만큼 대기 |
| `no_recent_activity` | proactive idle_sec 미충족 | 활동 대기 또는 직접 메시지 |
| `graphql_error` | GraphQL 연결 문제 | GraphQL 서버 상태 확인 |
| `model_error` | MODEL 호출 실패 | 모델/API 연결 상태 확인 |

---

## 7.7 스케줄러 공정성 — `Eio_guard.yield_meter`

### 개요

하나의 Eio 도메인에서 64개 keeper가 동시에 동작할 때 CPU 집약적인 keeper 루프가 스케줄러를 독점하는 문제가 발생할 수 있다. `Eio_guard.yield_meter`는 이 문제를 해결하기 위한 경량 작업 단위 카운터다.

### 적용 범위

`yield_step`은 아래 hot-path 루프에 계장돼 있다. 각 루프는 기본 임계값인 **1000 작업 단위**마다 `Eio.Fiber.yield`를 호출한다.

| 모듈 | 루프 | 비고 |
|------|------|------|
| `keeper_memory_bank` | compaction 행 선택 (`by_priority`, `by_recency`) | 수백 개 메모리 행 순회 |
| `server_bootstrap_loops` | autoboot 초기 pass 및 retry 루프 | keeper당 1회 |
| `keeper_keepalive_signal` | board signal 팬아웃 — 실행 중인 keeper 메타 스캔 | 실행 중 keeper 수 |
| `keeper_supervisor` | sweep Phase 1 (entries 스캔) | in-memory, I/O 없음 |
| `keeper_supervisor` | sweep Phase 2·3·3.5 (keeper_names 순회) | 메타 파일 읽기 포함 |
| `keeper_supervisor` | `reconcile_keepalive_keepers` | 메타 파일 읽기 포함 |

### 의도적으로 적용하지 않은 범위

아래 경로는 `yield_meter`를 적용하지 않는다. 각 이유는 괄호 안에 명시한다.

- **turn 루프 내부** — `Eio.Time.sleep`, gRPC, 파일 I/O 등 자연적인 Eio 스케줄러 양보점이 이미 존재.
- **heartbeat cycle** — 헤드에서 `Eio.Time.sleep`이 호출되므로 루프 전체가 이미 양보함.
- **단일 keeper 단일 작업** — 루프가 없으므로 계장 불필요.

### 관련 환경 변수

`yield_meter` 자체를 제어하는 환경 변수는 없다. 임계값(기본 1000)은 소스 코드에서만 변경 가능하며, 이는 의도된 설계다. 스케줄러 공정성은 운영 파라미터가 아니라 런타임 불변 속성으로 유지된다.

---

## 8. 설정과 동기화

### 8.1 설정 소스

Keeper 설정은 아래 소스에서 공급된다. 상세 우선순위는
`docs/spec/14-configuration.md` Section 12와 reload 계약은
`docs/TOML-RELOAD-MATRIX.md`를 참조. 파일 모델과 각 경로의 required/optional
필드는 [KEEPER-FILE-MODEL.md](./KEEPER-FILE-MODEL.md)를 참조.

| 소스 | 경로 | 역할 |
|------|------|------|
| Persona identity | `<PERSONAS_ROOT>/<name>/profile.json` | keeper의 정체성 / 기본 의도 |
| Keeper declaration | `<CONFIG_ROOT>/keepers/<name>.toml` | basepath별 배치 선언 / 예외적 override |
| Persistent runtime state | `.masc/keepers/<name>.json` | durable runtime save-state |
| Runtime artifacts | `.masc/keepers/<name>/...` | metrics / decisions / trajectory 등 상세 기록 |

별도 keepalive 등록 레지스트리는 없다. keeper는 durable always-on으로 취급되며,
멈춤은 설정값이 아니라 `paused` 또는 `keeper_down` 상태 전이로 표현한다.
정식 edit surface는 `profile.json`과 `keeper.toml`이다.

`keeper.toml`의 **전체 스펙 필드 목록**은
[`docs/KEEPER-FILE-MODEL.md` §2 Keeper Declaration](./KEEPER-FILE-MODEL.md#2-keeper-declaration)을 참조한다. 요약:

- **Canonical minimal**: `[keeper]` 테이블에 `persona_name`만. 나머지는 persona 기본값에서 해석.
- **Overlay fields**: `goal`, `tool_access`, `sandbox_profile`, `network_mode`, `active_goal_ids` 등 배치별 override 전용. Runtime/model selection은 keeper TOML overlay가 아니라 `runtime.toml [runtime.assignments]`가 소유한다.
- **Allowed value sets**: `tool_access`는 candidate profile tool name string 배열, `sandbox_profile ∈ {local, docker}`, `network_mode ∈ {none, inherit}`. 실제 실행 가능 여부는 descriptor/registry availability, `tool_denylist`, per-turn OAS allowlist, eval gate까지 통과해야 한다.
- **Removed / hard-rejected**: `runtime_id`, `model`, `runtime_ref`, `models`, `allowed_models`, `active_model`, `presence_keepalive*`, `trigger_mode`, `initiative_*`, `policy_mode`, `policy_shell_mode`. 로드 시 에러로 실패한다.
- **Unknown keys**: canonical/removed 둘 다 아닌 key는 **boot 시 warning** 후 무시된다 (`keeper TOML <path> has unknown keys: ...`). 과거에 `legacy_scope`/`scope_kind` 같은 dead config가 축적된 적이 있으므로 warning을 발견하면 정리한다.

Definitive source는 코드의 `canonical_keeper_toml_key_names` (`lib/keeper/keeper_types_profile.ml`)와 `removed_keeper_input_key_names` (`lib/keeper/keeper_config.ml`)다.

운영 기준 active config root는 `MASC_CONFIG_DIR`가 있으면 그 디렉토리이고, 없으면 `<MASC_BASE_PATH>/.masc/config`다. `repo/config`는 체크인된 seed source이며 live root가 아니다. low-level resolver에는 추가 fallback이 있지만, 운영 기준은 `docs/BOOT-ENV-STATE-INVENTORY.md`를 따른다.

### 8.2 Template 변경 반영

실행 중인 keeper의 declarative source는 전부 같은 방식으로 반영되지 않는다.

| 소스 | 반영 방식 |
|------|----------|
| `keepers/<name>.toml` | 다음 supervisor sweep에서 re-sync될 수 있음 |
| persona `profile.json` | TOML이 없을 때 다음 supervisor sweep에서 fallback source로 re-sync될 수 있음 |
| `runtime.toml` | startup-only. 서버 재시작 필요 |

즉시 fresh 재생성이 필요하면 아래 경로를 사용한다.

```text
masc_keeper_down(name: "sangsu")
masc_keeper_up(name: "sangsu")
```

`keeper_down`이 persistent meta를 제거하고, `keeper_up`이 declarative source에서 fresh로 재생성한다.

### 8.3 base-path 주의사항

`--base-path` CLI 인자는 workspace/base 경로다. runtime root는 항상 `<base-path>/.masc/`로 계산한다. `scripts/run-local.sh`는 `MASC_BASE_PATH=<target>` 및 `--base-path <target>`을 넘기며, 그 결과 data root가 `<target>/.masc/`가 된다. `start-masc.sh`는 shared/full-runtime 경로로 유지된다.

dir-local 실행에서 shared keeper 상태가 보이지 않는 것은 정상이다. 공유 keeper 상태가 필요하면 shared/full-runtime 경로를 사용해야 한다.

해결: dir-local 개발은 `scripts/run-local.sh --target-dir <dir>`를 사용하고, shared `.masc/`를 봐야 할 때만 `./start-masc.sh --http` 또는 explicit `--base-path`를 사용한다.

이 값은 workspace/base 경로이며, explicit `MASC_CONFIG_DIR`가 없을 때는 `<MASC_BASE_PATH>/.masc/config`를 resolved config root의 첫 후보로도 사용한다. bare `~/.masc`는 operator home의 `.masc`로 해석될 수 있으므로 runbook에서는 `<base-path>/.masc` 또는 fully resolved path를 쓴다.

### 8.4 모델 실행

모델 선택은 resolved config root의 `runtime.toml`이 유일한 권위다. Keeper 설정에 모델 필드를 직접 지정하지 않는다. keeper별 override는 `[runtime.assignments]`에 keeper 이름을 key로 적고, 없으면 `[runtime].default`를 사용한다.

---

## 부록: 관련 문서

| 문서 | 용도 |
|------|------|
| [BOOT-ENV-STATE-INVENTORY.md](./BOOT-ENV-STATE-INVENTORY.md) | boot / path / state / active config inventory |
| [GLOSSARY.md](./GLOSSARY.md) | 용어 정의 |
| [QUICK-START.md](./QUICK-START.md) | repo workspace collaboration 시작 경로 |
| [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md) | retired command-plane reference |
| [SPEC-INDEX.md](./spec/SPEC-INDEX.md) + [01-system-overview.md](./spec/01-system-overview.md) | 아키텍처 SSOT |
| [EXECUTE-RUNBOOK.md](./EXECUTE-RUNBOOK.md) | Execute flag matrix + dark-launch observer 절차 |
| [ENV-CONTRACT.md](./ENV-CONTRACT.md) | 환경변수 reload class + Execute §4 |
