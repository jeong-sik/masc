# RFC-0354 — 용량 유발 컴팩션이 lease 없는 cycle 에서 실행되어 100% 거부된다 (결정 요청)

**Status**: Draft — 결정 요청
**연관**: #25713 (guard 부재/bind 실패 붕괴), #25773 (선제 경로 생산자 0), #25461 (retry 래치 도입), #25783 (dispatch 전 거부, 머지 대기)
**제약**: RFC-0000 §1.2 LAW 1 (No dead-end) · CLAUDE.md 워크어라운드 거부 기준 §2 (typed variant 우선)

---

## 1. 사실 (2026-07-27 fleet 실측)

`<base-path>/.masc/keepers/*/runtime-manifests/` 의 `context_compacted` 레코드 **2,506건 전부**가 자율 트리거를 달고 있고, 성공은 **0건**이다.

| `decision.trigger` | 건수 |
|---|---|
| `provider_overflow` | 2,506 |
| (그 외) | 0 |

| `decision.error` | 건수 |
|---|---|
| `compaction rejected: exact_execution_guard_failed` | **2,438** |
| `compaction retry suspended after 3 consecutive failures; reactive prepare refused before the summarizer call` | 66 |
| `compaction rejected: exact_target_selection_failed` | 1 |
| `checkpoint generation is missing` | 1 |

> **초안 정정 (2026-07-27)**: 이 표의 최초 버전은 guard 부재를 **2건**으로 적었다. 매니페스트는 크기 초과 시 `<name>.jsonl.1` 로 회전하는데(`lib/keeper/keeper_types_support.ml:240-258`), 측정 도구가 `*.jsonl` 만 glob 해서 회전된 세대를 통째로 놓치고 있었다. 회전분을 읽으면 65 → 2,506 건이고 guard 부재는 2 → **2,438** 건이다. 결론은 바뀌지 않지만 **규모가 두 자릿수 다르다** — guard 부재는 래치를 채운 소수의 사건이 아니라 압도적 다수의 실패다.

guard 부재가 전체의 97% 다. 래치(#25461) 66건은 그 뒤에 오는 결과다.

대표 레코드 (sangsu, 2026-07-25T09:31:46Z):

```json
{"keeper_name":"sangsu","keeper_turn_id":16320,"event":"context_compacted",
 "status":"retryable_failure",
 "decision":{"trigger":"provider_overflow",
   "error":"compaction rejected: exact_execution_guard_failed",
   "clock_refs":{"lane":"memory_context","elapsed_ms":100507}}}
```

`elapsed_ms: 100507` — 100초를 쓰고 버려졌다.

> **정정 (2026-07-27)**: 이 레코드는 **최댓값**이며 전형이 아니다. 2,506건 전체 분포는 `min=2310ms p50=2947ms p90=3434ms max=130769ms total=2.3h` 다. 즉 전형적인 거부는 3초짜리로 이미 싸다. 이 RFC 의 논거는 **비용이 아니라 2,506회 시도 / 0회 성공** 이며, 비용을 근거로 쓰지 않는다.
>
> **그 뒤 확인 (같은 날)**: 위 문단은 "대부분의 거부가 provider 호출 전에 실패할 가능성"을 미확인으로 남겼는데, 확인 결과 **반대**다. `Exact_execution_guard_absent` 는 값 생성 기준 코드베이스 전체에서 한 곳(`lib/keeper/keeper_compaction_llm_summarizer.ml:1330`)이고, 그 지점은 `` `Flow (Ok flow_success) ``(:1292, provider 응답 성공) → `plan_of_json … | Ok plan`(:1329, 유효 plan 파싱) 두 겹의 성공 분기 안에 있다. 다른 경로로 도달할 수 없다.
>
> 따라서 **2,438건 전부가 provider 를 호출해 응답을 받고 쓸 수 있는 컴팩션 plan 을 만든 뒤 lease 가 없다는 이유로 버렸다.** `p50=2947ms` 는 호출을 안 했다는 뜻이 아니라 이 keeper 들의 요약이 그만큼 빠르다는 뜻이다. 근거는 제어 흐름이며 독립 채널 교차검증은 불가했다(`raw-traces` 는 keeper 턴 단위라 컴팩션 flow 를 담지 않는다 — 75파일 중 0건).

### 1.1 배제한 원인들

이 RFC 가 다른 설명을 배제했다는 근거를 남긴다. 같은 증상이 반복 오진되었기 때문이다.

| 가설 | 상태 | 근거 |
|---|---|---|
| 자율 트리거가 발화하지 않는다 | **반증** | 70/70 이 `provider_overflow` |
| 선제(`Context_measured`) 경로가 없어서다 | **부분적, 무관** | 사실이나(#25773) 반응형 경로는 발화하고 있고 그것도 거부된다 |
| exact-output 레인에 서빙 가능한 슬롯이 없다 | **반증(오늘 기준)** | `compaction_exact` 1/2 슬롯 도달 가능 (`provider_probe` 실측). `exact_target_selection_failed` 는 2,506건 중 **1건** |
| 래치가 원인이다 | **반증** | 래치는 결과다. 66건이며 guard 부재 2,438건 뒤에 온다 |

---

## 2. 구조 — guard 는 stimulus lease 의 부산물이다

guard 는 cycle 이 event-queue stimulus lease 를 claim 했을 때만 생성된다 (`lib/keeper/keeper_heartbeat_loop.ml:1363-1370`):

```ocaml
let dispatch_guard =
  match !claimed_lease with
  | None -> None
  | Some lease -> Some (exact_execution_guard ~base_path ~keeper_name ~lease)
```

`lib/keeper/keeper_compaction_llm_summarizer.mli:99-102` 가 이 의미를 이미 문서화한다 — "In production the guard is constructed only when the cycle claimed an event-queue stimulus lease, so this reports a missing lease rather than a persistence fault."

한편 용량 유발 컴팩션은 **오버플로가 발생한 그 cycle 안에서 인라인으로** 시도된다 (`lib/keeper/keeper_unified_turn.ml:206-224`, `recover_provider_context_overflow_in_lane`). 그 cycle 이 lease 를 들고 있는지는 컴팩션 필요 여부와 무관하다. proactive cadence tick 으로 깬 cycle 은 `wake = Proactive_tick` 이고 lease 가 없다.

### 2.1 운영자 경로는 왜 다른가

운영자 컴팩션은 인라인이 아니라 **stimulus 로 들어온다**. `Keeper_event_queue.Manual_compaction_requested` (`lib/keeper_runtime/keeper_event_queue.mli:94-96`): "The tool only enqueues this stimulus; the owning Keeper consumes it under its turn slot."

stimulus 로 들어오면 그 cycle 은 정의상 lease 를 claim 한 cycle 이고, guard 가 존재한다.

> **미검증**: 운영자 경로가 end-to-end 로 성공하는 것을 이 실측에서 확인하지는 못했다 — 매니페스트 70건이 전부 `provider_overflow` 라 manual 성공 사례가 표본에 없다. 여기서 주장하는 것은 "구조적으로 lease 를 얻는다"까지다.

### 2.2 그래서 현재 계약은 이렇다

> 자율 컴팩션은, 오버플로가 마침 stimulus 를 처리 중인 cycle 에서 발생했을 때만 성공할 수 있다.

이 조건은 어디에도 선언되어 있지 않고, 코드가 그것을 강제하지도 않는다. `?exact_execution_guard` 가 optional 이라 호출자가 없이도 호출할 수 있고, 실패는 dispatch 이후에야 드러난다(#25783 이 그 순서만 고쳤다).

---

## 3. 결정 요청

### 안 A — 용량 유발 컴팩션을 stimulus 로 만든다 (권고)

`recover_provider_context_overflow_in_lane` 이 인라인 컴팩션을 시도하는 대신 typed stimulus 를 enqueue 한다. 운영자 경로와 같은 모양이 되고, 소비하는 cycle 은 lease 를 들고 있으므로 guard 가 존재한다.

- 새 payload 변형이 필요하다 — `Manual_compaction_requested` 를 재사용하면 자율/운영자 구분이 소실되고, 그 구분은 G-6 이 판정하는 축이다. `Capacity_compaction_requested of Compaction_trigger.t` 가 트리거를 함께 나른다.
- `Keeper_event_queue.payload` 는 닫힌 합타입이라 소비자 누락은 컴파일 타임에 잡힌다 (`keeper_event_queue.mli:98-101`).
- 그 다음에야 `?exact_execution_guard` 를 필수 인자로 닫을 수 있고, `Exact_execution_guard_absent` 가 실패 타입에서 사라진다.

**비용**: `?exact_execution_guard` 는 lib/test **43개 지점**을 관통한다 (`rg -n "\?exact_execution_guard" lib/ test/`). 단계를 나눠야 한다.

**리스크**: 오버플로한 턴이 즉시 컴팩션되지 않고 다음 cycle 로 미뤄진다. 그 사이 같은 오버플로가 반복될 수 있으므로 dedup 이 필요한데, `Keeper_event_queue` 는 이미 dedup/urgency 를 가진다 (`keeper_event_queue.mli:5-7`). 새 메커니즘을 만들지 않는다.

### 안 B — guard 없는 cycle 의 컴팩션을 유예로 분류한다

`Exact_execution_guard_absent` 를 실패가 아니라 유예로 취급한다. 선례가 있다 — `Exact_owner_unregistered_deferred -> Owner_generation_deferred` (`lib/keeper/keeper_post_turn.ml:516`).

- **장점**: 작다. 래치가 채워지지 않으므로 66건의 봉쇄가 사라지고, lease 를 든 cycle 이 오면 성공한다.
- **단점**: 성공을 **우연에 맡긴다**. lease 를 든 cycle 에서 오버플로가 다시 발생해야 하고, 그 확률은 선언되지 않은 채 남는다. #25461 이 막으려던 무한 재시도와 경계가 모호해진다.
- 안 A 의 1단계로는 타당하나, 종착지로는 부족하다.

### 안 C — 현 상태를 계약으로 확정한다

"자율 컴팩션은 stimulus cycle 에서만 가능하다"를 문서화하고 guard 부재를 정상 거부로 선언한다.

- 이 경우 `max_context` 선언은 관대한 provider 아래에서 사실상 표시용으로 강등된다 (#25773 의 안 (A) 와 같은 귀결).
- 채택한다면 G-6 을 폐기하거나 판정 기준을 바꿔야 한다. **지금처럼 천장을 선언해두고 아무 일도 일어나지 않는 상태보다는 정직하다.**

---

## 4. 권고

**안 A**, 3단계로:

| 단계 | 내용 | 검증 |
|---|---|---|
| A-1 | `Capacity_compaction_requested` payload 추가 + `recover_provider_context_overflow_in_lane` 이 인라인 대신 enqueue | 매니페스트에 `context_compacted` 성공 1건 이상 (= APC G-6) |
| A-2 | 인라인 경로 제거 | 인라인 호출 지점 0건 (`rg`) |
| A-3 | `?exact_execution_guard` 를 필수 인자로 닫고 `Exact_execution_guard_absent` 삭제 | 실패 타입에서 생성자 소멸, 43개 지점 컴파일 통과 |

A-1 만으로 G-6 이 판정 가능해진다. A-3 은 그 다음이며, 그 전까지 `Exact_execution_guard_absent` 는 남는다.

## 5. 이 RFC 가 결정하지 않는 것

- **선제 경로**(#25773): provider 가 거절하지 않는 런타임에서 천장을 넘겨 진행하는 문제는 별개다. 이 RFC 는 *거절이 발생했을 때* 컴팩션이 성공할 수 있게 하는 것까지만 다룬다.
- **래치 임계값**(#25461): 3회라는 값을 건드리지 않는다. 안 A 가 성공하면 래치는 원래 목적대로 진짜 실패에만 반응한다.
- **레인 이중화**: 네 exact-output 레인 전부 실효 슬롯이 `glm-coding` 하나뿐이다(2026-07-27 실측). 별건.

## 6. 측정 방법

APC 하네스 G-6 (`~/me/.worktrees/masc-liveness-program/scripts/apc/selftest.py`) 이 판정을 이미 자동화한다:

- `autonomous_trigger_attempts` — 자율 트리거를 단 레코드 수 (현재 2,506)
- 성공 수 — 현재 0, 안 A 채택 시 1 이상이어야 한다
- `exact_output_lane_service` — 레인별 실효 슬롯 (현재 각 1/2)
- `refusal_elapsed_ms` — 거부 1건의 provider 시간 분포 (인용 가능한 단일 레코드가 아니라)

수동 재현:

```bash
python3 - <<'PY'
import json, pathlib, collections
c = collections.Counter()
# 회전된 세대(.jsonl.1, .2 …)를 반드시 포함할 것 — 빼면 97% 를 놓친다.
import glob as _g
for f in map(pathlib.Path, _g.glob(str(pathlib.Path.home()/"me/.masc/keepers/*/runtime-manifests/*.jsonl*"))):
    for line in f.read_text(errors="replace").splitlines():
        if '"context_compacted"' not in line: continue
        d = (json.loads(line).get("decision") or {})
        c[(d.get("trigger"), d.get("error"))] += 1
for k, v in c.most_common(): print(v, k)
PY
```
