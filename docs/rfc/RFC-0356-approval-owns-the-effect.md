---
rfc: "0356"
status: Draft
---

# RFC-0356: Approval owns the effect (replay the approved payload, do not require byte-identical resubmission)

**Status**: Draft
**Created**: 2026-07-27
**Fixes**: #25947
**Related**: #25943 (dogfood full-cycle ledger)

## 배경

Gate가 external effect를 `Deferred{Judge_requested}`로 미루면, 승인이 나도 그 효과는 실행되지 않는다. 실행되려면 Keeper가 **바이트 단위로 동일한 도구 호출을 다시 내야** 한다. `keeper_approval_queue.ml consume_approved_resolution`이 grant를 소비하는 조건이

```
entry.name = keeper_name
∧ entry.tool_name = tool_name
∧ entry.input_hash = normalized_input_hash input
```

이기 때문이다. 재제출 주체는 LLM이다.

## 문제

**비결정적 생산자에게 결정론적 재현을 요구하는 계약이다.**

2026-07-27 라이브 실측 (executor, task-002, `.masc/audit-approvals/2026-07/27.jsonl`):

| operation | 재시도 입력 성격 | pending→resolved | grant_consumed |
|---|---|---|---|
| `tool_execute` | `git clone <url> <dir>` — 짧아 재현됨 | 다수 | 38 |
| `filesystem_write` | 긴 `content`/`old_string`/`new_string` — 모델이 매 턴 다른 페이로드 생성 | 6쌍 | 1 |

결과: 편집이 승인돼도 반영되지 않고, 재시도는 새 `approval_id`로 다시 defer되어 livelock. Keeper가 스스로 "stuck in a loop submitting partial edits. The file hasn't been modified"라고 진단한 뒤 태스크를 cancel하고 이탈했다(실측).

파일 편집이 구조적으로 불가능하므로 코드 수정형 작업 전체가 막힌다.

### 이것은 게이트 결함이 아니다

`Auto_judge` 모드가 모든 요청을 defer하는 것은 설계다 (`keeper_gate.ml` `decide_from_selected_mode`, `keeper_gate_mode.ml let default = Auto_judge`). Sandbox confinement is not an authorization exemption, and edited arguments form a different request.

위반된 것은 같은 §3.4의 다른 불변식이다: **"approval 요청은 durable commit + Keeper lane 즉시 해제(lane-held time = 0)"** 는 "승인 후 그 효과가 실행된다"를 전제한다. 현재는 lane을 놓아준 뒤 승인된 효과를 실행할 주체가 없다.

## 왜 매칭 완화가 답이 아닌가

지문(`request_fingerprint = SHA256(canonical(input))`)에는 대상·부모의 `device`/`inode`가 들어간다 (`keeper_alerting_path.ml resource_identity_to_yojson`, `path_effect_to_yojson`). 이는 **TOCTOU 방어**다 — 승인된 것은 "이 경로"가 아니라 "이 파일 객체"다. inode를 지문에서 빼면 심볼릭 링크 교체 공격면이 열린다. `content`를 빼면 승인한 내용과 다른 내용이 쓰인다.

즉 매칭 완화(CLAUDE.md 워크어라운드 거부 기준: 안전검사 약화)는 배제된다.

## 제안

승인의 의미를 바꾼다:

> **현재**: 승인 = "동일한 재제출을 허가한다" (authorization of a resubmission)
> **변경**: 승인 = **"이 효과를 소유한다"** (ownership of the effect)

승인이 resolve되면 **서버가 저장된 페이로드로 그 효과를 실행**하고 결과를 Keeper lane에 전달한다. Keeper는 아무것도 재현하지 않는다.

### 실행 가능성: 페이로드는 이미 durable하다

`.masc/gate/pending.json`의 delivery entry는 `input_hash`뿐 아니라 **raw `input`을 이미 저장**한다 (라이브 확인: entry keys = `id, keeper_name, tool_name, input_hash, input, sequence, requested_at, turn_id, ...`). 스토리지 변경 없이 replay가 가능하다.

`filesystem_write`의 경우 저장된 input이 효과 전체를 담는다 (`file_write_gate_input`): `effect`(pinned locator = device/inode 포함), `requested_target`, `content`, `old_string`, `new_string`, `replace_all`.

### 보존되는 안전 속성

| 속성 | 보존 방법 |
|---|---|
| TOCTOU 핀 | 저장된 locator의 `device`/`inode`를 **실행 시점에 검증**. 불일치면 typed 실패(승인 무효). 우회가 아니라 강화 — 지금은 재현이 안 되면 아무것도 검증되지 않는다 |
| 승인한 내용만 실행 | 실행 입력이 승인 입력과 **동일한 객체**다. 모델이 다른 내용을 끼워 넣을 경로가 사라진다 |
| edited args = 새 요청 | 유지. 다른 인자는 애초에 다른 요청이며, 이전 승인은 자기 페이로드만 실행한다 |
| at-most-once | 기존 `grant_consumed` 플래그 + durable delivery 스냅샷 재사용 |

### 변경 지점

| 파일 | 변경 |
|---|---|
| `lib/keeper/keeper_approval_queue.ml{,i}` | 승인 resolve 시 저장된 `(tool_name, input)`을 조회하는 typed 접근자 노출 (이미 저장 중이므로 read 경로만) |
| `lib/keeper/keeper_gate.ml` | `cycle_grant_of_resolution` 경로를 "grant 발급"에서 "승인된 효과 실행 요청" 으로 확장. `Consumption_not_matching` fall-through(현 livelock 지점)는 replay가 성립하면 도달 불가가 된다 |
| `lib/keeper/keeper_tools_oas_bundle.ml` | resolution을 다음 LLM 턴의 grant로만 넘기지 않고, replay 결과를 원래 deferred 호출의 tool_result로 전달 |
| `lib/keeper/keeper_tool_filesystem_runtime.ml` | 저장된 gate input에서 효과를 재구성해 실행하는 진입점 (LLM 인자 파싱 없이) |

### 검증

- 회귀 테스트: 승인 후 **다른** 페이로드로 재시도해도 (a) 승인된 효과가 정확히 1회 실행되고 (b) 재시도 페이로드는 실행되지 않는다
- TOCTOU 테스트: 승인과 실행 사이에 대상 inode가 바뀌면 typed 실패, 파일 불변
- 멱등성 테스트: 같은 approval_id 2회 resolve → 실행 1회
- 라이브: keeper가 단일 파일 multi-edit 작업을 완료하고 diff가 디스크에 존재. 원장 #25943 편집 스테이지 ✅ 전환

## 범위 밖

- Gate 모드 정책(Auto_judge가 모든 것을 defer하는 것) 변경 — 별개 결정이며 운영자 소관 (`Manual`/`Auto_judge`/`Always_allow` 3모드는 대시보드에서 설정)
- 판정 왕복 지연(실측 18~23초)의 처리량 문제 — replay가 착지한 뒤 별도로 다룬다

## 대안과 기각 사유

| 대안 | 기각 사유 |
|---|---|
| wake 페이로드에 원본 input을 실어 보내 재제출시킴 | 여전히 모델 충실도에 의존. 큰 페이로드를 컨텍스트로 왕복해 컨텍스트 비용(성공지표)을 악화 |
| `input_hash` 비교 완화 / 경로·연산 단위 승인 | 안전검사 약화. 승인한 페이로드와 실행할 페이로드가 달라진다 |
| 지문에서 `device`/`inode` 제거 | TOCTOU 방어 상실 |
