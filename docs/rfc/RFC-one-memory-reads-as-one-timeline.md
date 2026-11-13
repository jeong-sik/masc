---
rfc: "one-memory-reads-as-one-timeline"
title: "기억 한 건은 쓰인 때부터 사라질 때까지 한 줄로 읽힌다"
status: Draft
created: 2026-11-13
updated: 2026-11-13
author: claude
supersedes: []
superseded_by: null
related: ["keeper-recall-reaches-the-turn", "a-memory-remembers-who-said-it", "0519", "0418"]
---

# 기억 한 건은 쓰인 때부터 사라질 때까지 한 줄로 읽힌다

## 0. 요약

운영자는 기억 한 건이 어디서 왔고, 언제 꺼내 쓰였고, 어디로 갔는지를 한 줄로 보고 싶다.
지금 TUI 는 그렇게 보여 주지 못한다. 이유는 넷이다.

1. 화면이 저널의 마지막 50줄만 읽는다. 실패한 줄과 바뀐 것 없는 줄도 50줄에 든다.
2. 꺼낸 기록과 턴마다 고른 기록은 다른 파일에 있다. 어느 화면도 저널과 합치지 않는다.
3. 고른 기억이 실제로 요청에 들어갔는지는 서버 프로세스 안의 값으로만 있다. 남는 기록이 없다.
4. 저널 줄은 대부분 턴이 없다. Keeper 세션의 trace 만 있다.

지난 개선(Ctrl-O 트리)은 고침과 흡수를 따라 id 를 잇는다. 그래서 "고치면 id 가 바뀐다"는 이유가 아니다.
그 트리는 50줄 창 안에서만 잇고, 꺼냄·주입을 합치지 않고, 방향 없이 넓혀서 형제 기억의 과거까지 끌어온다. 시간 순 줄이 아니라 그래프다.
"어떻게 됐는지 기록 없이 사라짐"도 지금은 생기지 않는다(§1.4: 10-26 이후 0건).

화면 밖에도 끊김이 하나 있다. Keeper 의 successor recall 은 ordered program 밖에서 일어난 흡수를 따라가지 않는다. 지금 흡수는 거의 다 program 밖에서 일어난다. 그래서 recall 이 묶어 둔 기억이 흡수되면 그 길은 "후계 없이 은퇴"로 끝난다(§1.1).

고치는 규칙은 하나다. **기억 한 건의 줄은, 그 기억의 조상과 자손에 대해 기록된 사건을 시간 순으로 늘어놓은 것이다.**
조상과 자손은 기록된 운명(대체 링크, 흡수)을 방향대로 따라 닿는 id 다. 화면은 이 projection 을 읽는다.

| 층 | 무엇 | 저장 변경 |
|---|---|---|
| L1 | 한 기억의 줄을 만드는 읽기 경로와 TUI 줄 화면. 저널 전체를 읽는다 | 없음 |
| L2 | 요청마다 고른 기억의 본문이 들어갔는지 recall 평가 기록에 남긴다 | 줄 종류 하나 덧붙임 |
| L3 | 턴 안에서 쓰인 줄의 `turn_ref`, 닫힌 운명 타입 (방향만) | hard cut. 끊는 방법은 별도 RFC |

## 1. 지금 구조 (main 202e915a2397)

### 1.1 기억과 id

- 사실은 `{claim, category, first_seen, last_seen, origin, basis}` 다(`lib/keeper/keeper_memory_os_types.ml` 509~516행).
- id 는 `"sha256:"` 에 claim 바이트의 SHA-256 을 붙인 것이다(779~783행). 같은 claim 을 다시 쓰면 같은 id 다. 지운 뒤 다시 쓰면 한 id 에 삶이 둘 생긴다.
- 고치기는 제자리에서 하지 않는다. `keeper_memory_write` 에 `supersedes` 를 주면 새 id 가 생기고, 같은 commit 이 옛 사실을 빼면서 대체 링크와 이유를 함께 남긴다(`lib/keeper/keeper_memory_os_current_fact_ops.ml` 159~185행).
- 지우면 snapshot 의 `facts` 에서 줄이 빠진다. 무덤 표시는 없다(107~152행).
- 빠진 사실의 운명은 다섯 곳에 흩어져 있고, 모두 선택이다.
  - 대체 링크: 저널 줄의 `revision_links`(`lib/keeper/keeper_memory_os_journal_codec.ml` 93~95행).
  - 버린 이유: 저널 줄의 `dropped`. 이유는 자유 글이고 commit 함수의 선택 인자다(`lib/keeper/keeper_memory_os_types.ml` 300~303행).
  - 흡수: 다른 파일 `<k>.memory-absorbed.jsonl`(`lib/keeper/keeper_memory_absorbed.ml` 6~18행).
  - 지지 무효: `change.invalidated` 의 `missing_premise_ids`.
  - ordered program 의 stage 안 결정.
- 운영자가 대시보드에서 지운 것은 저널에 Keeper 철회와 같은 `Explicit_retract` 로 남는다. trace 자리에 계획 id 가 들어갈 뿐이다(`lib/server/server_dashboard_http_keeper_memory_cleanup.ml` 261~271행).
- 이미 빠진 사실을 대체하면 대체 링크가 남지 않는다(`lib/keeper/keeper_memory_os_current_update.ml` 287~291행).
- 기억이 다음 기억으로 이어지는지 따라가는 코드는 이미 있다. successor recall 은 대체 링크를 방향대로, revision 순서로 따라간다(`lib/keeper/keeper_memory_os_successor_recall.ml` 110~131행).
  - 흡수는 ordered program 안의 것만 따라간다(171~173행). 계약도 그렇게 적는다(`lib/keeper/keeper_memory_os_current.mli` 677~689행).
  - program 밖에서 흡수된 기억은 링크 없이 빠진 것으로 보여 "후계 없이 은퇴"(`Retired_without_successor`)로 끝난다. 흡수 기록 파일에는 `into` 가 있다.
  - 흡수 기록 파일은 W44~W46 세 주에 4,317줄이 늘었다. ordered program 줄은 저널 전체에 1줄이다(§1.4).
  - 활동 projection 은 같은 흡수를 commit 에 이어 Absorbed 로 보인다(§1.3). 화면과 recall 이 같은 기억의 끝을 다르게 말한다.

### 1.2 기록 파일

`<keepers>` 는 보통 `.masc/config/keepers` 다.

| 파일 | 담는 것 | 턴 |
|---|---|---|
| `<keepers>/<k>.memory-journal.jsonl` | commit 마다 더한·뺀 사실, 대체 링크, 버린 이유, 지지 무효, ordered program | ordered program 줄만 그 program 이 읽은 턴들의 `turn_ref`. 나머지는 `source.trace_id` 만 |
| `<keepers>/<k>.memory-absorbed.jsonl` | 흡수: `memory_id` → `into`, 흡수된 사실 | `trace_id` 만 |
| `<keepers>/<k>.memory-events.jsonl` | retrieved{query}·retracted·revised | `trace_id` 만 |
| `.masc/keepers/<k>.decisions.jsonl` | memory_search 의 query 와 맞은 id | 있을 때만 |
| `.masc/keepers/<k>/memory-selection-evaluations.jsonl` | select 판정 | `purpose` 안에 |
| `.masc/keepers/<k>/memory-recall-evaluations.jsonl` | 턴마다 자동으로 고른 id 와 id 마다 결과 | 있음 |

코드: events `lib/keeper/keeper_memory_os_events.ml` 13~23행, decisions `lib/keeper/keeper_tool_memory_runtime.ml` 1309~1332행, selection `lib/keeper/keeper_workspace_memory_selection_io.ml` 14·43~50행(턴은 `lib/keeper/keeper_memory_select.ml` 111행의 purpose), recall `lib/keeper/keeper_memory_recall_evaluation.ml` 136·245~293행.

- 한 행위가 두 번 적힌다. 둘을 잇는 행위 id 는 없다.
  - search: events 와 decisions(`lib/keeper/keeper_tool_memory_runtime.ml` 1302~1332행).
  - select: events 와 selection 평가(`lib/keeper/keeper_memory_select.ml` 164~175행).
  - 고침·철회(운영자 지우기 포함): 저널과 events.
  - events 를 쓰는 곳은 이 셋뿐이다. `rg "Keeper_memory_os_events\.(Retrieved|Retracted|Revised)" lib/` 가 9곳을 찾고, 모두 위 행위 안에 있다.
- `ctx.turn_ref` 는 search·select 에는 넘어가고 write·retract 에는 넘어가지 않는다(`lib/keeper/keeper_tool_runtime.ml` 375~399행).
- Librarian commit 줄에는 입력 `turn_ref` 의 trace 만 남고 턴 번호는 빠진다(`lib/keeper/keeper_librarian_durable_commit.ml` 425·522행).
- 고른 기억의 본문이 요청에 들어갔는지, 용량 때문에 상태 줄만 갔는지, 본문이 없었는지는 `delivery` 의 mutable 값이다(`lib/keeper/keeper_memory_recall_blocks.ml` 17~73행). 시도마다, 요청마다 다시 정해지고 한 턴 안에서도 바뀐다.
- 턴마다 실제 system prompt 와 메시지는 provider 입력 snapshot 으로 남는다(`lib/keeper/keeper_provider_input_snapshot.mli` 1~16행). 거기서 어떤 기억이 들어갔는지 알려면 렌더된 글을 읽어야 한다. 기억 id 로 된 기록은 없다.

### 1.3 지금 화면

- TUI 는 `memory-journal?limit=50&activity=1` 을 고정으로 부른다(`bin/masc_tui_http.ml` 4044행). 서버는 1~500 으로 자른다(`lib/server/server_dashboard_http_keeper_memory_reads.ml` 322행).
- 50 은 저널 줄 수다. 실패한 줄과 바뀐 것 없는 줄도 센다(`lib/keeper/keeper_memory_activity.ml` 68·75행).
- 서버는 저널의 꼬리만 뒤에서 읽는다. 요청마다 파일 전체를 읽던 때 scheduler domain 이 무거워져서 그렇게 바꿨다(`lib/keeper/keeper_memory_os_current_read_anchor.ml` 64~69행).
- 활동 projection(`lib/keeper/keeper_memory_activity.ml` 20~65행)은 commit 을 사실 단위 사건으로 나눈다: Created, Revised(옛 → 새), Absorbed(여럿 → 하나), Removed, Retracted, Invalidated, Reobserved, Relation_unavailable.
- Ctrl-O 트리(`bin/masc_tui_memory_lineage.ml` 30~38행)는 고른 사건의 id 와 끝점이 겹치는 사건을 방향 없이 넓혀 간다.
  - 같은 commit 에 있었다는 것만으로는 잇지 않는다.
  - 방향이 없어서, C 가 A 와 B 를 흡수했으면 A 의 그래프에 B 의 과거가 따라온다.
  - 50줄 밖의 과거는 없다.
- 회수 탭은 events 를 사실마다 요약한다: 꺼낸 횟수, 꺼낸 날 수, 마지막 꺼낸 때, 철회 수, 이전 id(`lib/keeper/keeper_memory_os_events.ml` 229~235행). 저널과 합치지 않는다.

### 1.4 측정 (2026-11-13, 라이브 저장소를 읽기만 함)

스크립트는 저널마다 commit 이 뺀 사실의 id 를 claim 에서 다시 계산했다. 그리고 다섯 곳(§1.1) 가운데 어디가 그 id 를 말하는지 셌다.
한 id 를 둘 이상이 말하면 대체 링크 > 버린 이유 > 흡수 > 지지 무효 > stage 순서로 하나만 셌다.
둘 이상이 말하는 id 는 2,693개다. 2,692개는 대체다. 대체는 링크와 버린 이유(`superseded_by <새 id>`)를 함께 쓴다(`lib/keeper/keeper_memory_os_current_fact_ops.ml` 175~185행). 나머지 1개는 버린 이유와 흡수다.

- 저널 29개, 125MB, 87,666줄이다(2026-09-22 ~ 11-13 UTC). 가장 큰 저널은 14.6MB, 7,705줄이다.
- commit 61,863줄 가운데 사실을 뺀 것이 16,073줄, 뺀 사실이 31,569개다.
- 운명: 대체 링크 2,692, 버린 이유 13,363, 흡수 12,816, 지지 무효 8, stage 0, 없음 2,690(8.5%).
- ordered program 줄은 모든 저널을 합쳐 1줄이다.
- 운명 없음은 모두 10-25 이전이다.

  | ISO 주 | 뺀 사실 | 운명 없음 (explicit_write) | 운명 없음 (librarian) |
  |---|---|---|---|
  | W39 | 8,364 | 95 | 0 |
  | W40 | 3,465 | 2 | 0 |
  | W41 | 7,062 | 1,871 | 0 |
  | W42 | 3,697 | 0 | 0 |
  | W43 | 2,906 | 0 | 722 |
  | W44 | 677 | 0 | 0 |
  | W45 | 2,034 | 0 | 0 |
  | W46 | 3,364 | 0 | 0 |

- W43 의 722건은 Librarian commit 38개에서 나왔다. 그중 33개 commit 의 711건이 10-20·10-21 이다. 가장 큰 commit 하나가 61개를 뺐다.
- W44(10-26) 이후 뺀 사실 6,075개는 모두 운명이 있다.
- Python 으로 저널 29개와 흡수 기록을 모두 처음 읽는 데 1.4초 걸렸다(로컬 장비 한 대, 한 번 잼).
- events 파일 33개는 모두 6.6MB 다.

## 2. 설계

### 2.1 규칙

기억 한 건의 줄은 그 기억의 조상과 자손에 대해 기록된 사건을 시간 순으로 늘어놓은 것이다.

- **방향**: 고른 기억에서 Revised·Absorbed 를 거꾸로 따라가면 조상이고, 앞으로 따라가면 자손이다. 방향 없이 넓히지 않는다.
- **형제**: C 가 A 와 B 를 흡수했으면, A 의 줄에는 "B 와 함께 C 로 흡수됨" 한 줄만 있다. B 의 과거는 따라오지 않는다.
- **삶**: 같은 id 가 생겼다 빠지고 다시 생기면 삶이 둘이다. 줄은 고른 사건이 속한 삶에서 시작한다.
- **끊김**: 운명이 기록되지 않았으면 줄은 거기서 "무엇이 됐는지 기록 없음"으로 끝난다. 버린 이유만 있으면 그 이유로 끝난다. 짐작으로 메우지 않는다.
- **한 행위는 한 기록에서**: search 는 decisions, select 는 selection 평가, 고침·철회·흡수는 저널에서 읽는다. events 는 같은 행위의 사본이라 줄에 넣지 않는다. 한 행위가 두 번 보이지 않는다.
- 턴이 없으면 "턴 기록 없음" 이라고 적는다.
- 기록끼리는 id 로 맞춘다. 흡수 기록은 활동 projection 처럼 같은 commit 의 trace·시각·사실이 모두 같을 때만 그 commit 에 잇는다(`lib/keeper/keeper_memory_activity.ml` 96~99행). 시각이 비슷하다고 잇지 않는다.
- 한 번도 현재 사실이 아니었던 id(ordered program 의 중간 사실, commit 에 이어지지 않은 흡수 기록)는 줄에 넣지 않는다.
- ordered program 의 stage 들은 시각이 같다. stage 번호 순서로 놓는다.

### 2.2 L1 — 한 기억의 줄 (projection)

- 서버에 읽기 경로를 하나 둔다. 예: `GET /api/v1/keepers/:keeper/memory/:memory_id/timeline`. 이름은 L1 PR 에서 정한다.
- 대체 링크는 successor recall 과 같은 규칙으로 따라간다. 방향대로, revision 순서로 가고, 끊김은 타입으로 남긴다: `Unrecorded_lineage`, `Retired_without_successor`, `Invalid_transition`(`lib/keeper/keeper_memory_os_successor_recall.ml` 110~131행). TUI 의 방향 없는 넓히기는 쓰지 않는다.
- 흡수는 commit 에 이어진 흡수 기록의 `into` 를 같은 방향으로 따라간다. successor recall 은 이 흡수를 따라가지 않는다(§1.1). L1 이 들어가도 줄 화면은 "흡수됨", recall 은 "후계 없이 은퇴"로 같은 끝을 다르게 말한다. 둘을 맞추는 것은 L3 의 운명 타입이다(§2.4).
- 저널 전체를 읽는다. 50줄 창은 없다.
  - 요청마다 파일 전체를 읽지 않는다. 파일 정체(identity)로 키를 잡은 캐시를 둔다. `recall_journal_cache`(`lib/keeper/keeper_memory_os_current_journal.mli` 96~103행)와 같은 방식이다.
  - 읽기는 pool 작업에서 돈다. scheduler domain 에서 돌지 않는다.
  - OCaml 에서 14.6MB 저널을 처음 읽는 시간은 L1 PR 이 잰다.
- 시간 순으로 정렬해 돌려준다. 저장하지 않는다.
- TUI: 기억 상세에서 지금 트리를 여는 키가 줄 화면을 연다. 줄 하나가 사건 하나다. 시각, 사건, 턴(있으면), 바뀐 claim 이나 이유를 적는다. 읽는 순서와 말은 RFC-0519 를 따른다.
- 트리는 지운다. 합쳐짐은 줄 안에서 "A, B → C" 로 보인다.
- 대시보드도 같은 읽기 경로를 쓸 수 있다. 대시보드 화면은 이 RFC 범위 밖이다.

### 2.3 L2 — 요청에 들어갔는지 (덧붙임)

- Keeper 의 provider 요청마다 recall 평가 기록에 줄 하나를 남긴다. 줄 종류 `delivered` 가 는다.
- 칸: 지금 줄과 같은 `judgment_id`·`turn_ref`(`lib/keeper/keeper_memory_recall_evaluation.ml` 134~138행), provider 요청 순번, 결과.
  - 이 파일의 `request_id` 는 판정 모델에 보낸 요청이다(140~146행). Keeper 의 provider 요청과 다르다. L2 PR 은 두 이름이 섞이지 않게 다른 이름을 쓴다.
- 결과는 셋이다. `delivery` 의 상태와 같다.
  - `Body_sent`: 고른 기억의 본문이 요청에 들어갔다.
  - `Capacity_deferred`: 용량 때문에 본문은 빠지고 상태 줄만 갔다.
  - `No_body`: 그 요청에는 recall 본문이 없었다.
- 지금 이 값은 mutable 값으로만 있다. 남기지 않으면 그 요청이 무엇을 읽었는지 기억 id 로 다시 알 길이 없다.
- 새 줄 종류는 옛 줄을 다시 읽게 만들지 않는다. hard cut 이 필요 없다.
- L1 줄 화면이 이 줄을 "턴 T 요청에 들어감" 또는 "턴 T 에 골랐지만 용량으로 미룸" 으로 보인다.

### 2.4 L3 — 턴과 닫힌 운명 (방향, 별도 RFC)

L1·L2 만으로는 쓰기와 철회 줄에 턴이 없다. 그것을 남기려면 저널의 줄 모양이 바뀐다. 이 RFC 는 방향과 이미 알려진 대가만 적는다.

방향:

- 쓰는 쪽을 닫힌 타입으로 둔다. Keeper 의 턴 안 쓰기는 `turn_ref` 가 있어야 만들어진다.

  ```
  type writer =
    | In_turn of turn_ref              (* Keeper 도구 호출 *)
    | Librarian of { input_turn : turn_ref }  (* 입력을 만든 턴. 지금은 trace 만 남는다 *)
    | Operator of plan_id               (* 대시보드 지우기 *)
  ```

- 빠진 사실의 운명을 닫힌 타입 하나로 둔다. 다섯 곳에 흩어진 것을 한 곳으로 모은다.

  ```
  type fate =
    | Superseded_by of memory_id
    | Absorbed_into of memory_id
    | Invalidated of { missing_premises : memory_id list }
    | Retracted_by_keeper
    | Deleted_by_operator
    | Dropped_by_librarian of string     (* Librarian 이 쓴 이유 글 *)
    | Quarantined_with_snapshot
  ```

  - 측정상 W44 이후 운명 없는 빠짐은 0건이다. 이 타입은 10월의 구멍이 다시 생기지 못하게 한다.
  - 이미 빠진 사실을 대체할 때도 새 사실이 무엇을 잇는지 남긴다(§1.1).
  - 흡수가 저널 줄의 edge 가 된다. successor recall 이 그 edge 를 따라갈지는 별도 RFC 가 정한다. 따라가면 줄 화면과 recall 이 같은 끝을 말한다.
- events 는 행위의 사본이다(§1.2). 사본에 `turn_ref` 를 더하지 않고, 행위마다 기록 하나만 남긴다. events 가 하던 회수 요약(RFC-0418)은 그 기록에서 계산한다.

알려진 대가: snapshot 을 두고 저널만 지우면 화면만이 아니라 판단이 깨진다.

- Librarian 입력이 저널에서 은퇴한 사실을 읽는다(`lib/keeper/keeper_librarian_admission_owner.ml` 119~124행). 지우면 버렸던 claim 이 이유 없이 다시 들어올 수 있다.
- 대체할 대상을 저널에서 찾는다(`lib/keeper/keeper_memory_os_current_fact_ops.ml` 211~220행). 끊기 전에 Librarian 이 버린 대상을 대체하면 오류가 난다.
- successor recall 은 묶음이 생긴 뒤의 revision 을 모두 읽는다.
- 기다리던 publication·retraction receipt 가 옛 모양 줄을 다시 쓴다. 그러면 저널 읽기가 거절된다.

그래서 끊기는 저널 파일 지우기가 아니라, 지금 있는 purge 와 reset 경로(`Keeper_memory_lane.with_librarian_purge`, `Keeper_memory_os_current.with_program_reset`, `lib/server/server_dashboard_http_delete_actions.ml` 924~926행)를 지나야 한다. 저널 revision 을 이름으로 가진 것을 모두 같이 비워야 한다.
이 설계와 전체 대가는 별도 RFC 로 정한다.

### 2.5 하지 않는 것

- **안정 id(`fact_id`).** RFC keeper-recall-reaches-the-turn §5 층 2 가 방향으로 적은 안이다.
  - 조상과 자손은 기록된 운명에서 계산된다. W44 이후 운명은 빠짐없이 기록된다.
  - 안정 id 를 따로 저장하면 계산되는 값을 authority 로 다시 저장하는 것이다.
  - 운명이 기록되지 않은 빠짐은 id 로도 고치지 못한다. 누가 무엇을 이었는지 말해야 하는 것은 같다.
- **50줄 창 넓히기.** 창 크기는 최근성으로 자르는 대리 기준이다. 계보는 창이 아니라 링크로 정한다.
- **방향 없이 넓히기.** 형제의 과거가 섞인다.
- **꺼낸 기록과 저널을 시각이 가깝다고 맞추기.** id 로 맞춘다.
- **렌더된 프롬프트 글에서 기억을 찾기.** provider 입력 snapshot 의 글을 문자열로 읽어 기억 id 를 짐작하지 않는다. L2 의 타입 있는 줄을 쓴다.

## 3. 순서

| 층 | 범위 | 확인 |
|---|---|---|
| L1a | lib: 방향 있는 walk 로 조상·자손, 한 행위는 한 기록에서, 저널 캐시, 서버 읽기 경로 | 고침 두 번과 흡수 한 번을 거친 기억의 줄, 형제의 과거가 없음, 두 삶이 갈림, 끊김 줄, 옛 id 로 물어도 같은 줄 |
| L1b | TUI 줄 화면, 트리 지우기 | 보낸 요청(읽기 경로와 id) |
| L2 | recall `delivered` 줄 | 본문이 간 요청, 용량으로 미룬 요청, 본문 없는 요청에 쓰인 줄 |
| L3 | 별도 RFC | 이 RFC 범위 밖 |

L1a 와 L1b 는 한 스택으로 연달아 병합한다. 부르는 곳 없는 lib 층을 오래 두지 않는다.

## 4. 시험

masc 규칙대로 보낸 요청, 저장된 상태, 판정만 본다. 화면 글과 배치는 시험하지 않는다.

- L1a: 만든 저널·흡수·decisions·selection·recall 파일로 줄을 계산하고, 사건의 종류와 순서를 본다. events 의 사본 줄이 줄에 두 번 나오지 않는다.
- L2: `delivered` 줄의 결과가 그 요청의 `delivery` 상태와 같다.

## 5. 대안

- **창을 500으로 넓히기.** 지금 서버가 받는 최대다. 가장 큰 저널 7,705줄의 6.5% 다. 창은 여전히 최근성으로 자른다.
- **트리를 두고 꺼낸 횟수만 옆에 붙이기.** 턴과 순서가 없어서 "한 줄"이 아니다.
- **턴을 따로 적는 새 파일.** hard cut 을 피한다. 대신 한 사건의 사실이 두 파일로 갈라진다. 이 RFC 가 고치려는 것과 같은 모양이다.

## 6. 사용자 결정

| # | 결정 | 권장 | 근거 | 대가 |
|---|---|---|---|---|
| D1 | L1·L2 를 먼저 | 먼저 한다 | 저장 변경 없이 줄 화면이 생긴다 | L3 전까지 쓰기·고침·철회 줄에는 턴이 없다. 찾기·고르기·자동 recall 줄은 턴이 있다(§1.2) |
| D2 | L3 | 이 RFC 는 방향만 적고, 끊는 방법은 별도 RFC 로 | 끊기는 Librarian 판단, 대체, successor recall, 기다리는 receipt 를 함께 건드린다(§2.4) | 그 RFC 가 나올 때까지 턴 없는 줄이 쌓인다 |
| D3 | 안정 id | 두지 않는다 | §2.5 | RFC keeper-recall-reaches-the-turn §5 층 2 의 안정 id 방향을 이 RFC 가 대신한다 |
| D4 | Ctrl-O 트리 | 지운다 | 같은 사건을 줄 화면이 방향대로, 시간 순으로 보인다 | 합쳐짐 모양은 그래프가 아니라 줄 안의 "A, B → C" 로만 보인다 |

## 7. 확인하지 않은 것

- OCaml 에서 14.6MB 저널을 처음 읽는 시간. Python 측정만 있다.
- 저널이 돌아가며 잘리는지(rotation). 그런 코드를 찾지 못했다.
- 10-20·10-21 의 Librarian commit 들이 왜 운명 없이 사실을 뺐는지. 그 뒤로 0건이라 원인을 찾지 않았다.
- successor recall 이 program 밖 흡수를 따라가지 않는 것이 지금도 맞는 선택인지. 계약은 그렇게 적는다. 계약을 쓸 때 흡수가 주로 program 안에서 일어났는지는 찾지 않았다.
- events 를 없앨 때 RFC-0418 의 회수 요약이 decisions·selection 에서 같은 값을 내는지.
- Librarian 이 대화에서 뽑은 사실의 턴. RFC a-memory-remembers-who-said-it 가 정한다.
- tool call 기록(`.masc/tool_calls/`)의 보존 기간. 이 RFC 는 그 기록으로 턴을 맞추지 않는다.
