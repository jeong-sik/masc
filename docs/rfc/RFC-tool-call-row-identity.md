---
rfc: "tool-call-row-identity"
title: "도구 호출 장부의 행마다 쓸 때 정한 신원을 남긴다"
status: Draft
created: 2026-11-15
updated: 2026-11-15
author: claude
supersedes: []
superseded_by: null
related: ["0437", "0474", "0233"]
---

# RFC tool-call-row-identity: 도구 호출 장부의 행마다 쓸 때 정한 신원을 남긴다

- 상태: 초안.
- 이슈: #37517 (TUI Calls 화면이 불러온 호출을 전부 펼친다).
- 코드 좌표는 `origin/main` `e669729de303` 에서 읽었다.

## 0. 요약

TUI Calls 화면은 불러온 호출 100건의 tool·input·output 을 전부 펼쳐 한 목록으로 그린다(`bin/masc_tui_render_activity.ml:571-622`). #37517 은 목록을 호출마다 한 줄로 줄이고, 고른 호출 하나만 열자고 한다. 그러려면 cursor 가 「이 호출」을 가리켜야 한다. 새 스냅샷이 와도 같은 호출을 가리켜야 한다.

지금 장부에는 행 하나만 가리키는 값이 없다. execution_id 는 빠지기도 하고, 여러 행이 같이 쓰기도 한다. 색인의 위치는 장부를 회전하면 바뀐다(§1).

이 RFC 는 다섯 가지를 정한다.

1. `Keeper_tool_call_log.log_call` 이 행을 만들 때 `record_id` 를 하나 만들어 그 행에 같이 쓴다(D1).
2. `record_id` 는 행 바이트 안에 있으므로 회전·재시작·색인 재구축·보관 뒤에도 같다(D2).
3. `record_id` 가 없는 옛 행은 Calls 목록 decode 에서만 거부하고 개수를 보여 준다. 장부는 지우지 않는다(D3).
4. `/tool-calls` 응답은 바꾸지 않는다. 새 행에 `record_id` 가 실려 나간다. `tui_decode` 목록 decode 는 이 값을 필수로 받는다(D4).
5. 같은 `record_id` 가 두 행에 있으면 모호하다고 보고, 어느 한 행을 고르지 않는다(D5).

## 1. 지금 값으로는 안 되는 이유

### 1.1 execution_id

- `kc_execution_id : string option` 이다(`lib/tui_decode.mli:368`).
- composition run summary 행은 execution_id 없이 기록된다(`lib/keeper/keeper_tool_composition_surface_observation.ml:163-205`). #37517 본문이 「보여야 한다」고 한 Skill·JEV 영수증이 이 행이다.
- composition node 는 결과를 다시 확인해도 같은 execution_id 를 쓴다(`lib/keeper_tool_call_log.mli:373-377`). 그래서 한 스냅샷에 같은 execution_id 행이 여럿 있을 수 있다.
- execution_id 는 실행 하나를 부르는 이름이다. 행 하나를 부르는 이름이 아니다.

### 1.2 색인 위치(`Keeper_tool_call_index.position`)

- 위치는 `{ path; device; inode; generation; offset }` 이다(`lib/keeper_tool_call_index/keeper_tool_call_index.ml:113-114`).
- 장부를 회전하면 현재 파일 `DD.jsonl` 의 이름이 `DD.NNN.jsonl` 로 바뀐다(`lib/dated_jsonl/dated_jsonl.ml:1674-1687`, `Sys.rename`). 상한은 16 MiB 다(`lib/keeper_tool_call_log.ml:630`). 2026-10-16 에는 하루치가 77.6 MB 였다(`keeper_tool_call_index.ml:633`). 그러면 회전은 하루에 몇 번씩 일어난다.
- 회전 뒤에는 path 가 다르다. continuity 기록은 path 해시를 키로 쓴다(`keeper_tool_call_index.ml:522-524`). 그래서 색인은 새 이름의 파일을 처음 보는 파일로 읽고 generation 을 새로 만든다(`keeper_tool_call_index.ml:739-749`).
- Calls 화면이 읽는 최근 100행은 대개 현재 파일에 있다. 회전 한 번에 그 행들의 위치가 모두 바뀐다.
- `/tool-calls` 응답에는 위치가 실리지 않는다(`lib/server/server_dashboard_http_keeper_tool_calls.ml:8-12`, `314`).

### 1.3 행 내용

decode 한 필드나 행 바이트를 비교하면 같은 행을 다시 찾을 수 있다. 그러나 내용이 같은 두 번의 기록을 가르지 못한다. 그리고 그 비교는 쓰는 쪽이 정한 신원이 아니라, 읽는 쪽이 내용으로 짐작한 신원이다. §3.2 에서 다시 다룬다.

## 2. 결정

### D1. `log_call` 이 행을 만들 때 `record_id` 를 만든다

- 새 id 모듈 `Ids.Tool_call_record_id` 를 둔다. 값은 UUIDv4 문자열이다. `Ids.Agent_id` 와 같이 `Ids.new_uuid_v4` 로 만든다(`lib/types/ids.ml:43-51`).
- `log_call` 이 행 JSON 을 만들 때 한 번 만들어, `record_kind` 옆에 `"record_id"` 로 쓴다(`lib/keeper_tool_call_log.ml:1278-1281`).
- `Tool_call`·`Composition_run`·`Lifecycle_event` 세 종류 모두 쓴다. 장부에 쓰는 길은 `log_call` 하나뿐이다.
- 한 번의 `log_call` 이 만든 행은 실패 뒤 다시 써도 같은 값을 들고 간다. 큐에 다시 넣는 길(`keeper_tool_call_log.ml:706-737`)은 이미 만든 JSON 을 그대로 다시 쓴다.

`Ids.Execution_id` 처럼 `<prefix>-<ms>-<seq>` 꼴로 만들지 않는다. 그 counter 는 프로세스마다 0 부터 세고, 16비트에서 돌아간다(`ids.ml:34-41`). 같은 장부에 쓰는 프로세스가 둘이면 같은 밀리초에 같은 값이 나올 수 있다. UUIDv4 는 그 가정에 기대지 않는다.

### D2. 같은 행은 같은 `record_id` 를 가진다

`record_id` 는 장부 행 바이트 안에 있다. 행 바이트가 그대로면 값도 그대로다.

| 일 | 행 바이트 | `record_id` | 색인 위치 |
|---|---|---|---|
| 회전(`DD.jsonl` → `DD.NNN.jsonl` rename) | 그대로 | 같다 | 바뀐다(path·generation) |
| 서버 재시작 | 그대로 | 같다 | 같다(`.continuity` 에 남음) |
| 색인을 지우고 다시 만듦 | 그대로 | 같다 | `.continuity` 가 있으면 같다 |
| 백업에서 복원·복사(새 inode) | 그대로 | 같다 | 바뀐다 |
| 보관 기간이 지남 | 하루치 파일이 통째로 지워진다 | 행과 같이 사라진다 | 행과 같이 사라진다 |
| 실패 뒤 다시 쓰기 | 같은 바이트가 한 줄 더 생긴다 | 같은 값이 두 행 → D5 | 두 행이 다른 위치 |
| 압축 | tool_calls 장부에 없다 | — | — |

- 보관은 하루치 파일을 통째로 지운다(`lib/dated_jsonl/dated_jsonl_retention.mli:1-4`). tool_calls 는 운영자가 정한 기간만큼 보관한다(`Operator_window`, `lib/dated_jsonl/dated_jsonl_store.ml:132-141`).
- 장부 계약은 앞부분 바이트를 다시 쓰지 않는 것이다(`keeper_tool_call_index.mli:82-84`). 손으로 앞부분을 고친 행은 이 계약 밖이다. 그런 행의 `record_id` 는 고친 바이트가 말하는 값이다.

### D3. `record_id` 가 없는 옛 행은 Calls 목록 decode 에서만 거부한다

masc 는 1.0 전까지 저장 상태 하드컷을 허용한다. 이 RFC 는 읽는 쪽 하드컷을 고른다. 장부는 지우지 않는다.

- `tui_decode` 의 Calls 목록 decode 는 `record_id` 가 없는 행을 거부한다. 다른 Keeper 를 가리킨 행처럼 그 수를 센다(`lib/tui_decode.ml:2831`, `kcs_mismatched`). Calls 화면 머리에 「신원 없는 N줄은 그리지 않음」을 보인다(`bin/masc_tui_render_activity.ml:502-511` 과 같은 자리).
- `record_id` 가 있는데 문자열이 아니거나 비었으면 행 하나가 아니라 스냅샷 decode 가 실패한다. 쓰는 쪽과 읽는 쪽의 스키마가 다르다는 뜻이기 때문이다.
- execution_id 로 원본 호출 하나를 읽는 decode(`decode_keeper_call_exact`)는 `record_id` 를 요구하지 않는다. 대화 화면의 원본 호출 읽기는 옛 행도 지금처럼 연다.
- 장부를 읽는 다른 모듈은 `record_id` 를 읽지 않는다. 바뀌는 것이 없다.

고르지 않은 둘:

- **장부를 새로 시작하는 하드컷.** `docs/guides/DURABLE-STORE-HARD-CUT.md` 「Fresh state」 절차대로 `.masc/tool_calls/` 를 지우는 길이다. 코드는 가장 단순하다. 그러나 이 장부를 읽는 모듈이 적어도 12개다. Keeper 의 최근 행동(`keeper_own_recent_actions.ml`), ask 답 깨우기(`keeper_ask_answer_wake.ml`), trust snapshot·timeline, 대화 원본 호출, IDE, 도구 품질 화면이 기록을 잃는다. TUI cursor 하나를 위해 치를 값이 아니다.
- **「신원 없음」 갈래로 읽기.** 옛 행을 `Unrecorded` 같은 값으로 읽어 목록에 두는 길이다. cursor 는 그 행을 새 스냅샷에서 따라갈 수 없다. 그래서 L3 가 「신원 없는 행」을 위한 갈래를 하나 더 가져야 한다. 그 갈래는 L1 전에 쓴 행에만 쓰인다. 옛 행이 보관 기간을 지나면 죽은 코드가 된다. 헌법 `legacy_residue`(`docs/constitution.xml:492-499`)와 「A build reads only the stored format it writes」(`DURABLE-STORE-HARD-CUT.md` 「Fresh state」)에 어긋난다.

고른 길에서 개수를 세는 갈래는 옛 행이 사라진 뒤에도 쓸모가 있다. 쓰는 쪽이 `record_id` 없이 행을 쓰는 결함이 생기면 그 수가 보인다.

### D4. 받는 꼴

**`/tool-calls` 응답.** 바꾸지 않는다. 서버는 장부 행을 `annotate_row` 로 필드 하나만 덧붙여 그대로 내보낸다(`server_dashboard_http_keeper_tool_calls.ml:8-12`, `49`, `314`). L1 뒤에 쓴 행은 서버 변경 없이 `record_id` 를 싣고 나간다. execution_id 로 하나를 묻는 응답도 같다.

**`tui_decode`.** 목록 decode 만 바꾼다.

```ocaml
type keeper_call_row = {
  kcr_record_id : Ids.Tool_call_record_id.t;
  kcr_call : keeper_call;
}

type keeper_calls_snapshot = {
  kcs_keeper : string;
  kcs_entries : keeper_call_row list;  (* 서버 순서, 새 행이 끝 *)
  kcs_health : keeper_call_log_health;
  kcs_latest_age_s : float option;
  kcs_stale_reason : string option;
  kcs_mismatched : int;
  kcs_unidentified : int;  (* record_id 가 없어 거부한 행 *)
}
```

- `keeper_call` 에 `record_id` 필드를 더하지 않는다. 더하면 execution_id 로 하나를 읽는 decode 도 그 값을 요구하게 되고, 옛 행의 원본 호출을 열 수 없게 된다(D3).
- 지금 `kcs_entries` 를 읽는 곳은 셋이다(`bin/masc_tui_render_activity.ml`, `bin/masc_tui_keeper_call_evidence.ml`, `bin/masc_tui_types.ml:8288`). L2 는 이 셋이 `kcr_call` 을 읽게 고친다. 동작은 바뀌지 않는다.

**dashboard.** 바꾸지 않는다. `decodeToolCallEntry` 는 이름 붙은 필드만 골라 읽고 나머지는 버린다(`dashboard/src/api/dashboard-keeper-tool-calls.ts:319-388`). 새 필드 때문에 깨지는 곳은 없다. dashboard 가 행을 하나로 부를 일이 생기면 그때 `record_id` 를 받는다. 지금 쓰지 않는 타입 필드는 더하지 않는다.

### D5. 같은 `record_id` 가 두 행에 있을 때

- 색인 규칙은 이렇다. 「같은 execution_id 행이 여럿이면 다 돌려주고, 호출자는 한 행을 고르지 말고 거절한다」(`keeper_tool_call_index.mli:97-98`).
- UUIDv4 가 우연히 겹치는 경우를 빼면, `record_id` 가 두 행에 있는 경우는 한 번의 쓰기가 두 번 실린 경우뿐이다. 장부 쓰기는 바이트를 붙인 뒤에 commit 을 알린다(`dated_jsonl.ml:1695-1696`). 바이트가 붙은 뒤 commit 을 알리기 전에 실패하면, commit 이 안 된 것으로 보고 같은 JSON 을 큐 맨 앞에 다시 넣는다(`keeper_tool_call_log.ml:730-737`).
- 이 RFC 는 같은 규칙을 따른다. 서버는 두 행을 다 내보낸다. decode 도 두 행을 다 둔다. TUI cursor 가 가리킨 `record_id` 가 스냅샷에 두 번 있으면 「모호함」 갈래가 된다. 어느 한 행을 열지 않는다.
- `record_id` 는 execution_id 의 모호함을 풀지 않는다. execution_id 로 묻는 조회는 지금처럼 같은 id 행이 여럿이면 거절한다. 한 실행의 여러 행은 저마다 다른 `record_id` 를 가질 뿐이다.
- 이 RFC 는 `record_id` 로 장부를 직접 찾는 색인 열이나 조회를 더하지 않는다. 나중에 더하면 같은 규칙(다 돌려주고 호출자가 거절)을 따른다.

## 3. 고르지 않은 길

### 3.1 「나」: continuity 가 rename 을 따라가게 한다

같은 device·inode 면 rename 뒤에도 generation 을 물려받게 하고, 신원에서 path 를 빼는 길이다.

장점:

- 장부 스키마가 바뀌지 않는다.
- 옛 행도 처음부터 신원을 가진다.

단점과 부딪히는 규칙:

- **색인이 신원의 주인이 된다.** generation 은 장부가 아니라 색인 옆 `.continuity` 기록에 있다(`keeper_tool_call_index.mli:3-7`). 그 기록이 없거나 앞부분 증명이 실패하면 색인은 generation 을 새로 만든다(`keeper_tool_call_index.ml:739-749`). 그러면 모든 행의 신원이 바뀐다. RFC-0437 §5 「색인을 authority 로 쓰지 않는다 … 원장에 없는 사실이 색인에 있으면 그건 버그다」와 §3.2 「지우고 원장에서 다시 만든다」에 어긋난다.
- **generation 의 뜻이 바뀐다.** 지금은 「한 경로의 다음 continuity 는 늘 새 generation」이다(`keeper_tool_call_index.ml:618-620`). RFC-0474 L4h 4번은 이 사실에 기대어, 지우다 남은 `.observed` 기록이 다시 맞지 않는다고 말한다. 5번은 그 기록을 SQLite cursor 가 같은 continuity 에서 이어질 때만 믿는다. generation 이 경로를 옮겨 다니면, path 를 키로 둔 continuity 기록과 `.observed` 정리를 다시 설계해야 한다.
- **신원이 파일 시스템 사실이 된다.** 백업에서 복원하거나 복사하면 inode 가 바뀌고 신원도 바뀐다. 행 바이트는 그대로인데도 그렇다.
- RFC-0437·0474 의 소유 규칙을 고치는 일이다. TUI cursor 하나를 위해 바꿀 범위가 아니다.

### 3.2 「다」: 행 바이트의 SHA-256 을 신원으로 쓴다

장점:

- 장부가 가진 바이트에서 나온다. 회전·재시작·복사에도 같다.
- 쓰는 쪽을 바꾸지 않는다. 옛 행에도 값이 있다.

단점:

- 내용이 같은 두 번의 기록을 한 신원으로 묶는다. 장부 행은 사건이다. 같은 내용의 사건 둘은 사건 둘이다. 내용이 같으면 같은 대상이라는 규칙은 artifact blob 처럼 내용 주소를 쓰려고 만든 저장소에 맞는다.
- 읽는 쪽이 내용으로 신원을 짐작하는 길이다. 앞서 거절된 「decode 필드를 다 비교해 같은 행을 다시 찾는」 길과 같은 종류다.
- 서버가 읽을 때마다 원래 줄 바이트를 해시해야 한다. `recent_rows` 는 줄을 파싱한 JSON 을 돌려주고, 다시 직렬화한 바이트는 원래 줄과 다를 수 있다. 그래서 색인 읽기 길도 바꿔야 한다.

## 4. 층

| 층 | 내용 | 확인 |
|---|---|---|
| L0 | 이 RFC | `python3 scripts/rfc-generate-index.py --check` |
| L1 쓰기 | `Ids.Tool_call_record_id`, `log_call` 이 `record_id` 를 쓴다 | 두 번 쓴 행의 값이 다르다. 세 종류 행 모두 값이 있다. 작은 상한으로 회전시킨 뒤 다시 읽어도 값이 같다(`test/test_keeper_tool_call_log.ml:2843-2858` 의 회전 시험과 같은 방법) |
| L2 응답·decode | `keeper_call_row`·`kcs_unidentified`, 소비처 셋이 `kcr_call` 을 읽는다, Calls 머리의 개수 줄 | `record_id` 가 있는 행은 entries 로, 없는 행은 개수로, 비었거나 문자열이 아니면 `Error`. execution_id 로 하나를 읽는 decode 는 옛 행도 연다. `/tool-calls` 응답 행에 장부의 `record_id` 가 그대로 실린다 |
| L3 TUI cursor | Calls 목록은 호출마다 한 줄, cursor 는 `record_id`, Enter 는 고른 호출을 자르지 않고 읽기 문서로 연다, 읽기에서 Esc 는 목록으로, 목록에서 Esc 는 지금처럼 Keeper 상세로 | 상태 시험: j/k 가 cursor 의 `record_id` 를 옮긴다. Enter 가 그 `record_id` 의 호출을 연다. 새 호출이 들어와도 cursor 가 같은 `record_id` 다. 고른 행이 100건 창 밖으로 밀리면 「창 밖」 갈래다. 같은 `record_id` 두 행이면 「모호함」 갈래다. 화면 문구·배치는 시험하지 않는다 |

- L3 의 cursor 상태는 닫힌 합타입으로 둔다. 고른 것이 없음 / 고른 `record_id` / 창 밖으로 밀린 `record_id` / 모호한 `record_id` 넷이다. 창 밖이나 모호함이 되어도 다른 행으로 옮기지 않는다.
- L3 의 키는 대화 화면 call reader(`bin/masc_tui_chat_call_reader.ml:38-51`)와 같다. 새 키 규칙을 만들지 않는다. 키 표를 바꾸면 `docs/guides/TUI-KEYS.md` 를 생성기로 다시 만든다.
- L3 는 #37517 본문대로 1~4 KB 출력 100건 합성 기록에서, 바꾸기 전과 뒤의 렌더 시간을 잰다. 두 번째 자르기 상한은 넣지 않는다.
- 세 층은 native stack 하나로 쌓는다. L1 만 먼저 병합할지는 §6 에서 정한다.

## 5. 운영자에게 보이는 변화

- L1 뒤에 쓴 장부 행에는 `record_id` 가 있다. 행 하나가 50바이트쯤 늘어난다(`"record_id":` 와 36자 UUID).
- L2 를 배포한 직후, Calls 화면에는 L1 뒤에 쓴 행만 그려진다. 나머지는 「신원 없는 N줄은 그리지 않음」으로 보인다. Keeper 가 새 호출을 100번 하면 그 줄이 사라진다.
- 세 층을 함께 배포하면, 배포 직후 Calls 화면이 비고 개수 줄만 보인다. 그 Keeper 가 다시 도구를 부를 때부터 채워진다.
- dashboard, 대화 원본 호출 읽기, 장부를 읽는 다른 화면은 달라지지 않는다.

## 6. 운영자가 정할 것

1. 옛 행은 Calls 목록에서만 거부하고 개수로 보여 줄까요(D3), 아니면 장부를 새로 시작할까요?
2. 행 신원 필드 이름을 `record_id` 로, 값을 UUIDv4 문자열로 정해도 될까요?
3. 같은 `record_id` 가 두 행에 있으면, TUI 가 그 호출을 열지 않고 「모호함」으로 보여 줘도 될까요?
4. L1 을 먼저 따로 병합해 새 행을 쌓은 뒤 L2·L3 를 올릴까요, 세 층을 함께 올리고 배포 직후 빈 Calls 화면을 받아들일까요?
5. 고른 호출이 100건 창 밖으로 밀렸을 때, 나중에 `record_id` 로 장부를 직접 읽는 길을 열까요, 「창 밖」 갈래로만 둘까요?

## 7. 하지 않는 것

- 색인 위치를 응답에 싣는 일(§1.2).
- `record_id` 로 장부를 찾는 색인 열과 조회(D5).
- commit observer·라이브 이벤트에 `record_id` 를 싣는 일. Calls 화면은 스냅샷을 다시 읽어 따라간다.
- dashboard 타입 변경(D4).
- 옛 행에 `record_id` 를 채워 넣는 변환 도구.
