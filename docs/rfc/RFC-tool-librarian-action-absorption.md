---
rfc: "tool-librarian-action-absorption"
title: "Tool Librarian: 도구 호출 궤적을 읽어 반복 패턴을 컴포지션으로 흡수(Absorb)한다"
status: Draft
created: 2026-09-17
updated: 2026-09-21
author: jeong-sik
supersedes: ["keeper-writes-own-compositions"]
superseded_by: null
related: ["skills-as-tools", "tools-as-shell-commands", "0418", "keeper-writes-own-compositions"]
implementation_prs: []
---

# RFC: Tool Librarian — 도구 호출 궤적의 컴포지션 흡수 (Action Absorption)

> **관측과 제안의 범위**: §1.1~§1.2.1은 명시된 기록 창의 관측 결과이고, §2는 현재 Memory 구현을 설명한다. §1.3의 우려와 §3~§6의 자동 후보 생성·검증·승인·제거 규칙은 아직 구현·효과가 검증되지 않은 제안이다. §4 안의 날짜가 붙은 실측 표는 그 규칙과 구분되는 관측 자료이며, 규칙의 효과를 증명하지 않는다.

## 0. Summary

Memory OS의 Librarian은 관련 기억(`m1`, `m2`)을 새 claim으로 묶고, 재료 ID를 그 claim의 `absorbs`에 적는다. 재료는 현재 스냅샷에서 빠지지만 원문과 흡수 대상은 별도 기록에 남는다. 삭제(`dropped`)와 교정(`dropped` + `supersedes`)은 이와 다른 계약이다(§2).

이 RFC는 이 구분을 참고해 **Tool Librarian(별도 분석자)**이 Keeper들의 실행 로그(`tool_calls`)에서 반복되는 도구 호출을 찾아 **컴포지션(`keeper_compose_*`) 후보로 제안**하는 흐름을 다룬다. 컴포지션은 이후 호출을 묶는 것이며, 이미 일어난 호출 기록이나 턴을 지우는 것이 아니다. Memory 흡수가 구현됐다는 사실만으로 Tool Librarian의 자동 생성·검증·승인이 구현되거나 효과가 입증된 것은 아니다.

이 RFC는:
1. `tools-as-shell-commands` (Shell IR)의 실패(16일간 59,500회 호출 중 채택률 0%)와,
2. `keeper-writes-own-compositions`의 우려(일하는 키퍼의 집중 분산, 1회성 과적합)

를 배경으로, **오프라인 마이닝 + 샌드박스 사전 검증(Dry-run) + HITL 승인**을 거쳐 컴포지션 후보를 검토하는 아키텍처를 제안한다.

---

## 1. 배경과 실측 증거

### 1.1 범용 셸 문법 접근법(Shell IR)의 침묵과 실패
- `RFC-tools-as-shell-commands`는 모델에게 셸 스크립트 문법(`masc <tool>`)을 주고 런타임이 이를 0ms 인프로세스로 가로채려 했다.
- **실측 (2026-09-02 ~ 09-17)**:
  - `Execute` 호출 59,500건 중 `masc` 명령 시도는 단 6건(0.01%), 실제 도구 연결 성공은 **0건**.
  - 원인: 키퍼의 `Execute` 입력 중 85% 이상이 `sh -c "<text>"` 형태로 단일 포장되어 Shell IR 가로채기 자체가 발동하지 않았으며, 키퍼들은 파이프(`| head`)와 플래그(`--limit`)를 기대했으나 파서는 이를 거부했다.
  - 범용 문법 조합은 LLM의 비정형 셸 입력 앞에서 완전히 실패했다.

### 1.2 스킬 컴포지션의 실증과 '작성의 병목'
- 반면 고정된 DAG를 단일 도구로 패키징한 **스킬 컴포지션(`keeper_compose_*`)**은 실전에서 강력한 절감 효과를 입증했다.
- **실측 (총 2,164건)**: `<base-path>/.masc/tool_calls` 에서 모델이 부른 `keeper_compose_*` 줄(`composition_run_id` 가 있는 줄 제외)을 2026-09-01 00:00Z 부터 09-17 12:24Z 까지 센 값이다.
  창이 그 시각에 끝나는 이유는 그때 센 값이기 때문이다. 이 RFC 첫 커밋이 7분 뒤인 09-17 12:31Z 다. 2026-09-20 에 같은 창으로 다시 세어 같은 값을 얻었다.
  2,164건은 그 창에서 실제로 불린 컴포지션 이름 12개를 합한 수다. 아래 1번이 세는 "저장소에 정의가 있는 7개"와 다른 집합이다.
  - `msx-observe`: 813건 (화면 캡처 즉시 비전 분석 직결)
  - `work-intake`: 735건 (아침 조회 7개 도구를 28.5ms 만에 1턴으로 완료)
  - `what-arrived`: 342건. 이 컴포지션은 저장소 `skills/` 에 정의가 없다. 지운 기록도 없다.
    그래서 노드 목록으로는 셀 수 없고, 아래 1번이 세는 7개에도 들어가지 않는다.
- **한계와 문제점**:
  1. **작성의 병목**: 저장소 `skills/*/SKILL.md` 에 정의가 있는 컴포지션은 7개뿐이고, 그 일곱은 사람이 손으로 썼다.
     composition TOML 블록은 35~146줄이다(2026-09-20 에 `skills/*/SKILL.md` 의 ```` ```toml composition ```` 블록을 세었다).
     `tool-events` 의 `Assigned` 목록도 09-16 부터 같은 일곱 이름만 보여주고, 이 RFC 를 처음 쓴 09-17 의 저장소도 같은 7개였다.
     위 창에서 불린 이름 12개 가운데 나머지 5개는 저장소에 정의가 없어서, 누가 썼는지 이 저장소로는 확인할 수 없다.
     같은 로그를 08-18 까지 거슬러 보면 이름 16개가 나오는데, 지금 저장소에 정의가 없는 9개는 노드 목록이 없어 셀 수 없다.
     넷은 #36484 에서 파일이 지워졌고, 다섯은 저장소에 들어온 적이 없다.
  2. **검증 부재로 인한 지뢰 도구 배포**: 사람이 손으로 짠 `run-and-read`는 샌드박스 경계 검증을 거치지 않아, `microvm`에서 `keeper_spawn` 정책 거부(`policy_rejection`)로 **그날(09-17) 호출된 5건이 모두 실패**했다.
     같은 창 전체로는 40건 호출 중 37건이 실패했다.

### 1.2.1 지금 기록에서 후보가 몇 개인가 (§3.1 조건 1·2 실측, 2026-09-19)

§3.1 의 조건을 승인 전에 실제 기록에 대 보았다.

어디서, 어떻게 셌나:
- 데이터: `<base-path>/.masc/tool_calls/2026-08/26.jsonl` ~ `2026-09/18.jsonl`. 파일 하나가 UTC 하루이고, §3.1 대로 남아 있는 기록을 다 읽었다.
  `record_kind` 필드는 2026-08-26 17:18Z 줄부터 있다. 그 앞 줄은 이 정의로 읽을 수 없어서 뺐고, 아직 쓰이는 `2026-09/19.jsonl` 도 뺐다.
  `record_kind = "tool_call"` 이고 `runtime_contract.keeper_turn_id` 가 있는 줄 340,315개, 턴 49,320개.
- 턴은 `(keeper, runtime_contract.trace_id, runtime_contract.keeper_turn_id)` 로 묶고, 턴 안에서는 `ts` 순으로 놓는다.
  `(turn, planned_index)` 순서도 보았지만 쓰지 않았다. 09-12~18 에서 그 순서는 `keeper_analyze_image` 3건을 아직 만들어지지 않은 `masc_msx_screen` 결과 뒤에 놓았다(같은 `(turn, planned_index)` 가 374초 떨어져 두 번 나온 경우 하나, 더 큰 `planned_index` 가 약 1,500초 먼저 실행된 경우 둘).
  같은 `turn` 이 한 모델 응답을 뜻하지도 않는다. 09-15~16 의 `masc_msx_screen → keeper_analyze_image` 530번 중 383번이 같은 `turn` 인데, 383번 모두 뒤 호출이 앞 호출이 만든 artifact 를 받는다.
- `composition_run_id` 가 있는 줄 9,434개는 컴포지션이 모델 대신 부른 노드라 뺀다.
  이 줄을 넣으면 `keeper_compose_msx-observe` 한 번이 `masc_msx_screen → keeper_analyze_image` 한 번으로도 세어진다.
- 조건 1 은 §3.1 문안(서로 다른 Keeper 둘 이상)으로 셌다. 같은 도구만 이어진 시퀀스와 `keeper_compose_*` 가 낀 시퀀스는 뺐다.
- "이어짐": 한 발생 안에서 뒤 호출 `input` 의 값(문자열·숫자, 빈 문자열 제외)이 앞 호출 `output` 을 JSON 으로 읽었을 때 어떤 JSON Pointer 의 값과 같으면 이어졌다고 본다.
  JSON 이 아닌 출력은 통째로 문자열 하나(pointer `""`)로 본다.
  앞 호출 `input` 에도 있던 값(두 호출이 같은 값을 받았을 뿐이다)과 부른 Keeper 의 `runtime_contract` 에 있는 값(이름·trace id·sandbox 경로)은 세지 않는다.
- 판정할 수 있는 발생, 통과, 쓸 수 있음은 §3.1 조건 2 의 정의 그대로다.
  쓸 수 있는지는 창 안에서 그 도구의 가장 새 `route_evidence.composable_output` 으로 본다. 컴포지션이 지금 만나는 descriptor 가 그것이다.

| | 쌍 | 삼중 |
|---|---:|---:|
| 조건 1 통과 | 2,516 | 7,002 |
| └ 조건 2 통과, 지금 쓸 수 있음 | 0 | 1 |
| └ 조건 2 통과, 앞 도구 descriptor 가 막음 | 3 | 0 |
| └ 값이 바뀌는 문자열 이어짐은 있지만 통과 못 함 | 44 | 214 |
| └ 값이 바뀌는 숫자 이어짐만 있음 | 18 | 117 |
| └ blob 되읽기(`/_blob/*` → `keeper_artifact_read`)로만 이어짐 | 23 | 278 |
| └ 늘 같은 값만 이어짐 | 180 | 888 |
| └ 이어짐 없음 | 2,248 | 5,504 |

- 조건 2 를 통과한 것은 넷이다.

  | 시퀀스 | 대응 | 발생 | Keeper | 판정한 발생 | 막는 것 |
  |---|---|---:|---:|---:|---|
  | `keeper_spawn → keeper_spawn_wait → keeper_spawn_stop` | `/handle` → `/handle` (두 연결) | 4 | 2 | 4 | 없음 |
  | `BrowserRead → BrowserInteract` | `/url` → `/expectedUrl` | 111 | 3 | 14 | `BrowserRead` output schema 에 속성이 없다 → `Invalid_output_pointer` |
  | `BrowserRead → keeper_analyze_image` | `/artifact` → `/artifact` | 9 | 3 | 8 | 같은 이유 |
  | `masc_ask → masc_ask_withdraw` | `/ask_id` → `/ask_id` | 9 | 3 | 3 | `masc_ask` 가 `Opaque_output` → `Opaque_output_reference` |

  지금 쓸 수 있는 새 후보는 `keeper_spawn → keeper_spawn_wait → keeper_spawn_stop` 하나다.
  `run-and-read`(`keeper_spawn → keeper_spawn_wait → keeper_spawn_read`)와 같은 `keeper_spawn` 으로 시작하므로 §1.2 의 `microvm` 제약도 같이 진다.
  `BrowserRead → BrowserInteract` 는 111번 중 32번이 결과 크기 합으로 `Common.max_tool_result_wire_bytes` 를 넘었다(조건 3).
- `msx-observe` 자신의 쌍 `masc_msx_screen → keeper_analyze_image` 는 통과하지 못한다.
  판정할 수 있고 뒤 호출이 성공한 2,323번 중 2,322번은 `/artifact` 가 이어졌다. 나머지 1번(09-11)은 캡처 212초 뒤에 다른 artifact 를 읽었다.
  §3.1 은 이런 발생이 하나라도 있으면 통과시키지 않는다.
- msx 삼중에서는 `masc_msx_screen → keeper_analyze_image` 연결만 이어진다. `masc_msx_press → masc_msx_screen`, `keeper_analyze_image → masc_msx_press` 연결에서는 JSON 값이 넘어가지 않는다.
  무엇을 누를지 분석 문장을 읽고 정하는 것으로 보이지만, 문장 안의 값은 찾지 않으므로 이 기록으로 확인되지는 않는다.
- 문자열 값이 이어졌지만 통과 못 한 쌍 가운데 대응이 뚜렷한 것:
  `keeper_spawn → keeper_spawn_wait` (`/handle`, 1,854번 중 1,673번),
  `masc_board_comment → keeper_memory_write` (`/id` → `/board_comment_id`, 2,950번 중 136번),
  `WebFetch → keeper_artifact_read` (`/full_text_sha256` → `/sha256`, 680번 중 142번),
  `masc_board_post → keeper_memory_write` (`/id` → `/board_post_id`, 310번 중 24번).
  `masc_board_comment`·`masc_board_post`·`WebFetch` 는 `Opaque_output` 이라 통과하더라도 지금은 pointer 를 쓸 수 없다.
- blob 되읽기는 앞 결과가 한도를 넘어 blob 으로 저장된 뒤 `keeper_artifact_read` 로 다시 읽는 사슬이다.
  둘을 묶어도 결과가 같은 한도를 다시 넘으므로 조건 3 에서 빠진다.
- 조건 1 은 거친 체다. 쌍 2,516개 가운데 조건 2 를 통과한 것은 3개이고, 지금 쓸 수 있는 것은 0개다.
- 조건 2 는 노드끼리 출력을 넘기지 않는 컴포지션을 후보로 올리지 못한다. `work-intake` 가 그런 모양이다
  (`skills/work-intake/SKILL.md`: "서로의 출력을 쓰지 않으므로 `after` 는 없다").
  이 기간에 `work-intake` 는 Keeper 25명이 1,046번 불렀고, 같은 일곱 도구를 모델이 풀어서 연달아 부른 적은 순서와 상관없이 0번이다.
  이어짐이 없는 쌍 가운데 뒤 호출 입력이 매번 똑같은 쌍은 222개다. 뒤 도구는 `keeper_time_now` 51개, `keeper_context_status` 40개, `masc_plan_get_task` 20개, `keeper_lane_status` 20개 순이다.

한계:
- 로그는 출력을 앞 4,000 byte 만 남기고, 직렬화가 그보다 긴 입력은 JSON 대신 문자열로 남긴다(`lib/keeper_tool_call_log.ml` 의 `max_output_len`, `input_to_json`).
  그래서 판정할 수 없는 연결이 쌍 152,053개 중 33,315개, 삼중 399,252개 중 87,370개다. 통과 여부는 판정할 수 있는 발생만 보고 정했다.
- JSON 문자열 안에 든 값(`Execute` 의 stdout 에 찍힌 id 같은 것)은 찾지 않는다.
- 이어짐은 "그 값이 그 pointer 에 있었다"는 뜻이다. 모델이 거기서 읽었다는 증거는 아니다.
- 조건 3 은 모든 발생을 `Common.max_tool_result_wire_bytes` 와 비교했다. `Masc_agent_core` 레인에서 돈 발생은 한도가 더 크므로, 넘은 수가 실제보다 많게 세어졌을 수 있다.

측정 스크립트는 저장소에 넣지 않았다. §5 Phase 1 마이너가 이 정의를 코드로 옮긴다.

### 1.3 일하는 Keeper가 직접 만들 때의 우려 (`keeper-writes-own-compositions` 검토)
`RFC-keeper-writes-own-compositions`는 일하는 키퍼가 런타임에 `keeper_compose_save`로 제안하자고 했다. 이 RFC가 보는 우려는 둘이다. `keeper_compose_save`는 구현된 적이 없어서 둘 다 잰 값은 없다.
1. **작업 방해(Task Distraction)**: 코딩/디버깅 턴에 복잡한 TOML DAG를 조립하느라 에이전트의 주의력과 토큰이 그쪽으로 샐 수 있다.
2. **1회성 과적합(Catalog Pollution)**: 단 한 번 마주친 특수 상황을 컴포지션으로 제안하여 시스템 프롬프트의 Tool Definition을 불릴 수 있다.

이 RFC는 이 두 우려를 근거로 **"일하는 키퍼"와 "도구를 흡수/합성하는 분석자"를 나누자고 제안한다.**

---

## 2. 핵심 원리: 기억의 흡수(Memory OS)에서 행동의 흡수(Action OS)로

현재 Memory 계약은 [Librarian 프롬프트](../../config/prompts/librarian.md)의 유지·삭제·교정 절과 [RFC-0456 §4.2](RFC-0456-librarian-output-contract.md)에 따라 세 경로를 구분한다.

- **흡수**: 묶은 내용을 `new_claims`에 쓰고 재료의 짧은 ID를 그 claim의 `absorbs`에 적는다. 같은 ID를 `dropped`에도 넣거나 여러 번 흡수하면 [파서의 `translate_absorbs`](../../lib/keeper/keeper_librarian.ml)가 거절한다.
- **삭제**: 현재 기억에서 뺄 ID와 이유를 `dropped`에 적는다.
- **교정**: 옛 ID를 `dropped`에 적고, 이를 고친 새 claim의 `supersedes`에 같은 ID를 적는다. `supersedes`는 여러 기억을 묶는 필드가 아니다.

흡수할 때 [현재 스냅샷 저장소](../../lib/keeper/keeper_memory_os_current.mli)는 잠금을 잡은 시점에도 현재 스냅샷에 남아 있고 이번 교체로 빠지는 재료의 전체 fact와 `memory_id`·`into`를 [흡수 기록](../../lib/keeper/keeper_memory_absorbed.mli)에 덧붙인다. 기록에 실패하면 커밋하지 않는다. 이렇게 기록된 원문은 `keeper_memory_search`의 `absorbed` 또는 `all`에서 찾을 수 있다. 모델이 답하는 동안 이미 철회된 재료는 이 회차의 흡수 기록에 추가되지 않는다. 또 기록을 쓴 뒤 스냅샷 교체가 실패하면 미완료 회차의 행도 남을 수 있으므로, 흡수 기록 한 줄 자체가 커밋 성공 증명은 아니다.

완료 턴 범위의 소비 여부는 이 흡수 기록과 별개다. 현재 저장소의 `durable_range_id`와 범위 영수증이 Memory 스냅샷의 revision·SHA-256에 연결되고, [durable consumer](../../lib/keeper/keeper_librarian_durable_consumer.mli)는 progress 쓰기 실패 후 그 범위의 커밋이 확인되면 모델을 다시 부르지 않고 진행 위치를 복구한다. 이 복구 계약도 원래 턴이나 호출 기록을 삭제한다는 뜻은 아니다.

두 흐름은 같은 동작이 아니라 다음과 같이 비교할 수 있다.

| 비교 차원 | Librarian의 기억 흡수 — 현재 구현 | Tool Librarian의 행동 흡수 — 이 RFC의 제안 |
| :--- | :--- | :--- |
| **재료** | 현재 기억과 읽은 대화·도구 관측 | 기록된 도구 호출과 입출력 |
| **줄이려는 반복** | 같은 주제의 기억을 따로 유지하며 생기는 중복 | 중간 판단 없이 이어지는 도구 호출의 모델 왕복 |
| **판정 기준** | Librarian이 조건·수치·교훈과 출처를 살펴 묶을 내용을 판단 | §3.1의 재사용성·데이터 흐름·크기 조건으로 후보를 판정 |
| **흡수 행위** | `new_claims[].absorbs`로 재료와 새 claim을 연결하고, 재료 원문은 흡수 기록에 보존 | 기존 호출 기록을 근거로 컴포지션 후보를 만들고 검증·승인 후 이후 호출에 사용 |
| **결과** | 선택한 현재 기억 스냅샷과 검색 가능한 흡수 원문 | 여러 도구를 한 번에 부를 후보. 절감 효과는 해당 컴포지션의 실행에서 확인 |

기억 흡수는 모델이 내용을 읽고 판단한다. Tool 후보는 먼저 §3.1의 구조 조건을 충족해야 하므로, 모델이 함께 묶을 만하다고 판단할 내용이라도 출력→입력 연결이 없으면 후보가 되지 못한다.
[기존 컴포지션 7개 대조](https://github.com/jeong-sik/masc/pull/37351)에서는 3개가 이 구조 조건 밖에 있고, 출력 참조가 있는 4개도 §1.2.1의 판정에서 탈락했다. 이 대조는 같은 입력에 대한 모델 판단과 구조 조건의 비교 실험이 아니므로, 0/7을 이 차이 하나의 결과로 단정하거나 모델 판단으로 바꾸면 해결된다고 결론 내릴 수 없다.

[현재 기억의 recall](../../lib/keeper/keeper_memory_os_recall.ml)은 선택된 사실을 그대로 렌더링하며, 목표 항목 수나 고정 바이트 수로 줄이지 않는다. 도구 결과의 인라인 한도는 §3.1의 descriptor와 실행 레인을 함께 본다.

---

## 3. Tool Librarian 아키텍처

이 RFC는 Tool Librarian을 실시간 턴과 분리된 **오프라인/스탠드얼론 분석 파이프라인**으로 제안한다.

```
 [<base-path>/.masc/tool_calls/ 프로덕션 로그 (수만 건)]
                       ↓
 [1단계: 미흡수 궤적(Unabsorbed Trace) 시퀀스 마이닝]
   - N-gram 빈도 분석 (예: Tool A → Tool B)
   - 데이터 의존성 분석 (Tool A의 output이 Tool B의 input으로 직결되는가)
                       ↓
 [2단계: Tool Librarian 합성 판정]
   - "중간에 LLM의 주관적 추론이 필요 없는 결정론적 DAG인가?"
   - TOML 컴포지션 초안 자동 생성 (Param 바인딩 & Output Pointer 연결)
                       ↓
 [3단계: 샌드박스 Dry-Run 검증 게이트 (필수 Invariant)]
   - 실제 격리 환경(host, microvm)에서 자동 생성된 컴포지션 실행 테스트
   - exit code 0, timeout 미발생, §3.1의 각 호출에 적용되는 출력 정책과 한도 충족 여부 검증
                       ↓
 [4단계: Staged 제안 및 사람 승인 (HITL)]
   - "기록 09-12~09-18, Keeper 3명, 420회, /id → /post_id 예외 0, 한도 넘은 발생 0, Dry-run 통과"
   - PR 또는 TUI/Board 제안 카드로 발행 → 사람 승인 후 반영
```

### 3.1 흡수 판정 조건 (Absorption Criteria)
Tool Librarian은 다음 3가지 조건을 모두 충족할 때만 컴포지션 후보로 선별한다.
조건은 횟수·비율 문턱이 아니라 기록에서 일어난 일로 정한다.
마이너는 남아 있는 `tool_calls` 기록을 전부 읽고, 읽은 범위(첫 파일과 마지막 파일)를 후보 카드에 적는다.
기록이 얼마나 남는지는 `lib/keeper_tool_call_log.ml` 의 `retention_days` 가 정한다(`MASC_TOOL_CALL_LOG_RETENTION_DAYS`, 없으면 `retention_days_default`). 이 RFC 는 따로 기간을 정하지 않는다.
세는 방법과 한계는 §1.2.1 과 같다. 컴포지션이 대신 부른 노드 줄(`composition_run_id` 가 있는 줄)은 어느 조건에서도 세지 않는다.
1. **재사용성**: 서로 다른 Keeper 둘 이상이 각자의 턴 안에서 같은 시퀀스를 연달아 부른 기록이 있다.
   몇 번 불렀는지는 카드에 적지만 문턱으로 쓰지 않는다.
2. **결정론적 데이터 흐름 (Deterministic Pipelining)**:
   - Tool A의 출력 필드가 Tool B의 필수 입력 필드에 명확한 JSON Pointer(`pointer = "/id"`)로 사상될 수 있어야 함.
   - 기록으로 판정한다. 시퀀스의 연결마다 (앞 호출 pointer → 뒤 호출 필드) 대응 하나가, 판정할 수 있고 뒤 호출이 성공한 모든 발생에서 성립하고, 그 발생들에서 값이 늘 같지는 않아야 한다.
   - 판정할 수 없는 발생은 따로 세어 카드에 적는다. 앞 출력이 로그에서 잘려 JSON 으로 읽히지 않을 때, 앞 출력이 blob 으로 저장돼 기록에 `{"_blob": …}` 만 남았을 때, 뒤 입력이 로그 한도를 넘어 문자열로 저장됐을 때다.
   - 판정할 수 있는데 대응이 성립하지 않은 발생이 하나라도 있으면 통과하지 못한다. 마이너는 그 턴을 카드에 적고, 모델이 다른 값을 골랐는지 다른 이유인지는 Tool Librarian 이 그 턴을 읽고 적는다.
   - 앞 도구의 descriptor 가 `Json_output` 이고, 그 pointer 가 선언된 output schema 안에 있어야 한다.
     `Opaque_output` 이면 `Keeper_tool_plan.create` 가 `Opaque_output_reference` 로, schema 에 없는 pointer 면 `Invalid_output_pointer` 로 거절한다.
   - 중간에 LLM의 복잡한 자연어 추론이나 분기 선택이 개입해야 하는 경우는 흡수 대상에서 제외.
3. **크기 (Size Ceiling)**:
   - 발생마다 각 노드의 descriptor에 실제 적용되는 `model_output_projection`으로 결과 크기(`result_bytes`)를 판정한다. `model_projection_for_call`은 기본 `Store_above`를 `Masc_agent_core`에서 `Common.max_agent_core_inline_result_bytes`로 바꾸지만, descriptor가 지정한 `Inline_up_to`는 그대로 둔다. 예를 들어 `keeper_artifact_read`의 한도는 해당 descriptor의 `maximum_bytes`다.
   - `Store_above`의 한도를 넘으면 결과가 blob으로 저장되어 추가 읽기가 필요하다. `Inline_up_to`의 한도를 넘으면 `Inline_budget_exceeded` 오류가 된다. 둘을 같은 결과로 세거나, 노드 크기 합이 레인 기본값 아래라는 이유만으로 모든 결과가 inline이라고 판정하지 않는다.
   - 마이너는 넘은 발생 수를 카드에 적고 절감 예상에서 뺀다. 넘지 않은 발생이 하나도 없으면 후보가 아니다.
   - 실제 결과에는 노드마다 붙는 틀(`node_id`·`schedule`·`tool_use_id`)이 더해져 이 합보다 크다. 실제 크기는 §3.2 Dry-run 이 잰다.

### 3.2 샌드박스 Dry-Run 검증 (The Verification Invariant)
사람이 손으로 짠 `run-and-read`가 실패했던 전철을 밟지 않기 위해, **Dry-run 통과는 기계적으로 강제**된다:
- 생성된 TOML을 임시 등록하고, 테스트 샌드박스(`microvm` 타깃 포함)에서 모의 입력을 넣어 실제 실행.
- 아래 표에서 탓이 "컴포지션"인 실패가 단 1건이라도 발생하면 즉시 기각하고 로그를 남긴다.
- 등록한 뒤에도 같은 표를 쓴다(§4 실패).

컴포지션 호출이 실패하면 `Keeper_tool_plan_executor.cause` 하나가 남는다. 경우마다 탓을 정해 둔다.

| 실패 | 탓 | 이유 |
|---|---|---|
| `Plan_execution_failed` + `Unknown_node_id` | 컴포지션 | 계획에 없는 노드를 가리켰다 |
| `Plan_execution_failed` + `Input_template_resolution_failed` | 컴포지션 | pointer 나 param 이 값을 찾지 못했다 |
| `Plan_execution_failed` + `Input_validation_failed`, 거절된 필드가 `Literal`·`Output` 에서 옴 | 컴포지션 | 컴포지션이 만든 입력이 틀렸다 |
| `Plan_execution_failed` + `Input_validation_failed`, 거절된 필드가 `Param` 에서 옴 | 부른 쪽 | 모델이 넘긴 값이다. 풀어서 불렀어도 같은 거절이다 |
| `Plan_execution_failed` + `Output_validation_failed` | 컴포지션 | 앞 노드 출력이 선언한 schema 와 다르다. 풀어서 부를 때는 이 검사가 없다 |
| `Plan_execution_failed` + `Output_not_composable` | 컴포지션 | 참조할 수 없는 출력을 가리켰다 |
| `Node_observation_failed` | 컴포지션 | 실행기가 노드 결과를 기록하지 못했다. 풀어서 부를 때는 없는 단계다 |
| `Outer_completion_mismatch` | 컴포지션 | 호출이 기대한 완료 방식과 계획이 다르다 |
| `Tool_did_not_complete`, 노드 결과가 `Deferred` | 컴포지션 | inline 컴포지션 안에서 노드가 끝나지 않았다 |
| `Tool_did_not_complete`, 노드 결과가 `Failed` + `Policy_rejection` | 컴포지션 | 그 레인이나 sandbox 가 노드를 막는다(`run-and-read` 가 이 경우). 인자 검증 거절도 이 class 라 param 탓이 섞일 수 있다. 제거·수정 PR 에서 사람이 가른다 |
| `Tool_did_not_complete`, 노드 결과가 `Failed` + `Dependency_unavailable`·`Runtime_failure`·`Workflow_rejection`·`Operator_cancelled` | 노드 도구 | 그 도구를 그 입력으로 불렀으면 풀어서도 같은 실패다 |

---

## 4. 채택 계측과 퇴역

컴포지션은 한 번 등록되고 끝나는 정적 자산이 아니다. 마이너가 돌 때마다 컴포지션마다 두 수를 따로 센다.
범위는 §3.1 과 같이 남아 있는 `tool_calls` 기록 전체다. 그래서 두 수는 마이너가 얼마나 자주 도는지와 상관없다.

- **분자 `N_c`**: 모델이 `keeper_compose_<name>` 을 부른 횟수.
- **분모 `N_u`**: 같은 일을 모델이 풀어서 한 횟수. 컴포지션의 노드 도구를 한 턴 안에서 연달아 부른 경우를 센다.
  `after`·pointer 로 순서가 정해진 노드는 그 순서일 때만, 순서가 없는 노드는 어떤 순서든 센다.
- `N_u` 는 그때 그 Keeper 에게 컴포지션이 보였던 경우만 센다. 첫 호출 시각 전 마지막 `Assigned` 기록(`Tool_assignment_telemetry.emit_assigned`, data 디렉터리의 `tool-events`)의 `tool_list` 에 `keeper_compose_<name>` 이 있으면 보였던 것이다.
  등록하기 전이나 그 레인에 없던 때 풀어서 한 것은 세지 않는다.
- 두 수 모두 컴포지션이 대신 부른 노드 줄(`composition_run_id` 가 있는 줄)은 세지 않는다.
  이 줄을 분모에 넣으면 컴포지션을 부를 때마다 분모도 같이 늘어난다.

두 수를 비율 하나로 합치지 않는다. 비율이 낮다는 사실만으로는 "그 일을 아무도 안 한다"와 "그 일은 계속하는데 컴포지션을 안 쓴다"를 가를 수 없다.
두 경우는 정반대 행동을 요구한다.

| `N_u` (풀어서 함) | `N_c` (컴포지션) | 뜻 | 할 일 |
|---|---|---|---|
| 없음 | 없음 | 그 일이 사라졌다 | 제거 PR 을 사람에게 낸다 |
| 없음 | 있음 | 컴포지션이 그 일을 다 맡는다 | 그대로 둔다 |
| 있음 | 상관없음 | 컴포지션이 보였는데도 풀어서 한다 | 지우지 않는다. 풀어서 한 턴을 읽고 이유를 적는다 |

첫 줄(제거)은 남아 있는 `tool_calls` 기록 전체가 그 컴포지션을 처음 보인 뒤의 것일 때만 쓴다.
`tool-events` 에서 그 컴포지션이 처음 나온 시각이 남아 있는 기록의 첫 줄보다 늦으면 판정하지 않는다.
그래서 제거 판정이 보는 기간은 로그 보존 기간(`retention_days`, 없으면 `retention_days_default`)과 같다.
이 값은 로그가 디스크를 얼마나 쓸지로 정한 값이고, 이 RFC 가 고른 값이 아니다.
보존을 끄면(`MASC_TOOL_CALL_LOG_RETENTION_DAYS` 가 0 이하) 옛 기록이 계속 남아서, 한 번이라도 쓰인 컴포지션은 이 줄로 제거되지 않는다.

풀어서 한 턴에서 볼 것: 설명이 그 상황과 맞는가, 모델이 넘긴 입력을 컴포지션 param 으로 적을 수 있는가,
두 호출 사이에 모델 판단이 필요했는가(§3.1 조건 2 를 다시 본다).

실측(2026-08-26 ~ 09-18, §1.2.1 과 같은 기록):

| 컴포지션 | `N_c` | `N_u` (보였을 때만) | 할 일 |
|---|---:|---:|---|
| `msx-observe` | 912 (`msx-retro-mania` 906, 그 밖 3명 6) | 2,314 (`msx-retro-mania` 2,302, 그 밖 3명 12) | 풀어서 한 이유를 본다 |
| `work-intake` | 1,046 (Keeper 25명) | 0 | 그대로 둔다 |

- `msx-observe` 에서 먼저 볼 곳은 `skills/msx-play/SKILL.md` 다. 이 문서가 "`masc_msx_screen` … Pass the artifact to `keeper_analyze_image`" 라고 두 도구를 따로 부르라고 안내한다. 이것이 이유인지는 아직 확인하지 않았다.
- 보였는지 따지지 않으면 `msx-observe` 의 `N_u` 는 2,538 이다. 차이 224 는 그 Keeper 에게 컴포지션이 없던 때 풀어서 한 것이다.
- 노드 줄까지 분모에 넣으면 `work-intake` 의 분모는 0 이 아니라 520 이 되고, 520 모두 `work-intake` 가 대신 부른 노드다. `msx-observe` 의 분모도 2,538 이 아니라 3,429 가 된다.

**실패**: 등록한 뒤에도 §3.2 의 표를 그대로 쓴다.
탓이 "컴포지션"인 실패가 한 건이라도 나오면, 그 컴포지션을 §3.2 Dry-run 으로 되돌리고 고치는 PR 이나 제거 PR 을 사람에게 낸다.
입구에서 한 건으로 막는 실패를 등록 뒤에 비율로 봐줄 이유가 없다.
탓이 "노드 도구"나 "부른 쪽"인 실패는 풀어서 불렀어도 똑같이 났을 실패라 컴포지션 판정에 쓰지 않는다.

---

## 5. 단계별 구현 계획

### Phase 1: 시퀀스 마이너 도구 (`scripts/tool-call-sequence-miner`)
- `<base-path>/.masc/tool_calls/*.jsonl`을 스캔하여 키퍼별 연속 도구 호출 쌍(Pair) 및 삼중(Triplet) 빈도와 실패율을 집계하는 CLI 작성.
- 모델이 부른 호출만 센다(`composition_run_id` 줄 제외). §3.1 조건 1~3 과 §4 의 두 수를 §1.2.1 의 정의대로 낸다.

### Phase 2: 컴포지션 Dry-Run 테스트 러너 (`test_keeper_composition_dry_run`)
- 임의의 `[[compositions]]` TOML 조각을 받아 현재 등록된 `microvm` / `host` 러너에서 실제로 파싱 및 시험 실행을 해보는 테스트 하네스 구축.

### Phase 3: Tool Librarian 프롬프트 및 파이프라인
- `config/prompts/tool_librarian.md` 작성.
- Phase 1의 마이닝 결과와 Phase 2의 검증기를 엮어, 마이너가 돌 때마다 §3.1 세 조건을 통과한 후보와 §4 의 두 수를 카드로 제안하는 주기적 메타 워크플로 안착.
- 도는 주기는 배포의 schedule 이 정한다. §3·§4 의 규칙은 주기에 기대지 않는다.

---

## 6. 반론과 답

- **Q: 샌드박스 내부의 `masc` CLI Shim 방식과 상충하는가?**
  - **A: 상호 보완적이다.**
  - CLI Shim은 키퍼가 `Execute` 안에서 임의의 셸 파이프(`masc ... | jq`)를 자유롭게 치게 하는 **'동적 실행 레일'**이다.
  - Tool Librarian은 셸을 칠 필요조차 없는 정형화된 반복 패턴을 1턴짜리 고속 RPC로 묶어주는 **'정적 턴 흡수 레일'**이다. 둘은 충돌하지 않으며 서로 다른 최적화 지점을 담당한다.

- **Q: 카탈로그가 너무 많아지면 도구 선택 장애(Tool Choice Confusion)가 오지 않는가?**
  - **A: 개수 상한은 두지 않는다.**
  - §4 에서 두 수가 모두 없어진 컴포지션은 제거 PR 로 간다. 풀어서 쓰이는 컴포지션은 지우기 전에 이유를 본다.
  - 카탈로그 크기가 도구 선택을 흐리는지는 아직 잰 적이 없다.

---

## 7. 결론

관측한 기록에서는 Shell IR의 도구 연결이 성공하지 않았고, 수동 컴포지션에도 샌드박스 실패가 있었다. 이 결과만으로 자동 생성이 수동 작성보다 낫거나 §3.1의 조건이 충분하다고 결론 내릴 수는 없다.

Tool Librarian 자동화는 검토 중인 제안이다. 채택 여부를 정하려면 기존 컴포지션을 재현하는 범위, 잘못된 후보, 실제 실행의 안전성을 비교해야 한다. 이 RFC의 관측 기록은 그 비교의 근거이며, 자동 생성·검증·승인이 구현되었다는 증거가 아니다.
