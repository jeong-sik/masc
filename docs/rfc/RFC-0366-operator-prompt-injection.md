---
rfc: "0366"
status: Draft
---

# RFC-0366 — 운영자가 다음 턴의 컨텍스트에 한 문장을 넣는다

**Status**: Draft
**Author**: Claude Opus 5 (1M context)
**Date**: 2026-08-06

## 문제

운영자가 keeper 에게 무언가를 알리려면 지금은 세 경로뿐이다.

| 경로 | 도달 지점 | 수명 |
|---|---|---|
| board post / comment | 도구를 호출해야 읽힘 | 영구 |
| chat operation | 사용자 메시지로 도달 | 대화에 누적 |
| `Explicit_write` 메모리 | 회상 블록 | **영구** — 라이브러리안이 지울 때까지 |

세 번째가 실제로 쓰이는데, 그게 사고 경로다. 한 턴만 유효한 지시("지금 openssl 결정이 났으니 task-195 재개해도 된다")를 메모리에 넣으면 **영구 규칙이 된다.** #26729 가 정확히 이 모양이었다 — 라이브러리안 constraint 가 운영자 지시를 덮고, 한 번 승격되면 되돌릴 주체가 없다.

앞의 둘은 수명이 맞지만 도달이 불확실하다. board 는 keeper 가 도구를 호출해야 읽고, chat operation은 대화에 남아 매 턴 재전송된다.

**한 턴만 살고, 도구 호출 없이 도달하고, 전달 여부를 확인할 수 있는 경로가 없다.**

## 설계

### 새 프롬프트 블록

`Prompt_block_id` 에 변형 하나를 추가한다.

```ocaml
type t =
  | Persona
  | Dynamic_context
  | Temporal_summary
  | Memory_os_recall
  | Operator_note        (* 신규 *)
```

닫힌 합이므로 OCaml 쪽 모든 소비 지점이 컴파일 타임에 강제된다.

**TS 미러도 같은 변경 단위에 포함해야 한다.** `dashboard/src/api/dashboard-turn-records.ts` 의 `decodeTurnPromptBlockId` 는 화이트리스트이고 미지 id 에서 `null` 을 돌려주며, 그 결과 `decodeTurnBlock` 이 실패해 **turn-records 페이로드 전체가 무효**가 된다. 한쪽만 넓히면 대시보드가 조용히 어두워진다.

### 수명 — 한 턴 소모, 기록은 남는다

```
.masc/keepers/<name>/pending-note.json
```

```json
{ "text": "…", "created_at": 1786…, "created_by": "operator",
  "consumed_at": null, "consumed_turn": null }
```

조립 시점(`before_turn_params`)에 `consumed_at = null` 인 노트만 렌더한다. 렌더한 뒤 그 자리에서 `consumed_at`/`consumed_turn` 을 찍는다.

**소모 후 파일을 지우지 않는 이유**: 지우면 "전달됐다"와 "애초에 없었다"가 같아진다. 이 세션 내내 반복된 결함 모양이고, 운영자가 가장 먼저 물을 질문이 "그래서 들어갔나" 다. 남겨두면 `consumed_turn` 이 답한다.

새 노트를 쓰면 이전 노트를 덮는다. 큐가 아니다 — 큐면 다시 누적이고, 그건 chat operation이 이미 하는 일이다.

### 배치

조립 순서는 현재 `Dynamic_context` → `Temporal_summary` → `Memory_os_recall` 이다. `Operator_note` 는 **마지막**에 온다. 가장 최근 사실이고, 앞의 블록들과 충돌할 때 나중 것이 읽히는 위치다.

### 크기 상한

`MASC_KEEPER_OPERATOR_NOTE_MAX_BYTES`, 기본 4 KB. 초과는 **거부**하고 잘라내지 않는다 — 잘린 지시는 다른 지시다.

## 대안과 기각 사유

| 대안 | 기각 이유 |
|---|---|
| `Dynamic_context` 재사용 | 운영자 입력과 작업판 상태를 한 이름에 압축. 출처가 사라진다 |
| 블록 없이 조립 텍스트에 append | 타입도 기록도 없다. 이 저장소가 거부하는 모양 |
| 큐(여러 노트 누적) | chat operation이 이미 그 일을 한다. 누적은 영구화의 다른 이름 |
| 소모 후 삭제 | "전달됨"과 "없었음"이 구별 불가 |
| 만료 시각(TTL) | 턴 수가 시간보다 정확하다. keeper 가 안 돌면 시간만 지난다 |

## 무엇을 건드리지 않는가

- Memory OS — 이 경로는 메모리를 쓰지 않는다. 한 턴짜리 사실이 영구 저장으로 새는 것이 문제였고, 그 경계를 다시 넘지 않는다
- 라이브러리안 — 노트는 회상 대상이 아니다
- 도구 표면 — keeper 가 이 노트를 쓰는 도구는 없다. 운영자만 쓴다

## 검증

- 소모: 노트가 있는 상태로 두 턴을 돌리면 **첫 턴에만** 블록이 나타난다
- 기록: 소모 후 `consumed_turn` 이 그 턴 번호와 같다
- 덮어쓰기: 두 번 쓰면 뒤엣것만 남는다
- 상한: 초과 입력이 `Error` 이고, 잘린 텍스트가 저장되지 않는다
- 미러: 대시보드 디코더가 `operator_note` 를 받는다 (없으면 페이로드 전체 거부)
