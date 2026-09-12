---
rfc: "0450"
title: "witness 원장은 먼저 재고, 그 다음 WAL 이다"
status: Draft
created: 2026-09-12
updated: 2026-09-12
author: claude
supersedes: []
superseded_by: null
related: ["0448", "0445", "0380", "event-queue-admit-all-ready"]
implementation_prs: []
---

# RFC-0450: witness 원장은 먼저 재고, 그 다음 WAL 이다 (event-queue-witness-measure-then-wal)

## 0. Summary

keeper 마다 `keepers/<k>/event-queue-v19.json` 안에 `projected_dispositions` 목록이 있다.
큐 전이(ack, cancel, transfer) 하나가 끝날 때마다 그 전이의 요약 한 줄(witness)이 이 목록 앞에 붙는다.
지우는 코드는 없다. 전이 하나가 끝날 때마다 파일 전체를 pretty JSON 으로 다시 쓴다.
2026-09-12 13:04Z 기준 16 개 파일 23,918,385 B, witness 23,148 건이다.

감사 R9 는 "하루 6 GB" 라고 썼다. 그 수는 추정이다.
Codex 검토는 이렇게 반박했다. "커진다는 사실만으로 WAL 이 답이 되지는 않는다.
누가 만들고, 누가 보관하고, 누가 읽고, 얼마나 오래 필요한지부터 밝혀라."
이 RFC 는 그 순서를 따른다.

1. 먼저 잰다. 무엇을, 어느 파일에서, 얼마 동안 셀지를 §2.2 에 계약으로 적는다.
2. 측정이 §2.3 의 질문에 답한다. 핵심은 "witness 를 source incarnation 단위로 끊을 수 있는가" 다.
3. 답이 "끊을 수 있다" 일 때만 §2.4 의 설계로 간다. keeper 별 append-only 파일, incarnation 단위 정리, 64-hex ref 한 번 저장.
   답이 "끊을 수 없다" 면 측정 결과만 남기고 이 RFC 를 닫는다.

같은 문서의 §2.5 에 결정 5 의 "미배달 interval occurrence 합치기" 를 둔다.
RFC-0448(manual keeper) 이 이 절을 가리킨다. 둘 다 같은 큐 파일과 같은 witness 원장을 건드리기 때문에 한 곳에 둔다.

## 1. 배경 (실측)

### 1.1 파일과 숫자

감사 (merged.md R9, VERIFIER 재측정, 2026-09-12 03:29Z 스냅샷):

- 16 파일 23,232,137 B.
- witness 수: imp 0 / taskmaster 3 / kidsnote-slack-context-collector 35 / 나머지 1,052–2,632.
- pr-updater 2,632 건 (2,749,876 B), rondo 2,581 건 (2,633,361 B).
- witness 한 건이 파일에서 1,017–1,047 B. compact JSON 으로 찍으면 886 B.
- 가장 오래된 `applied_at_unix` 는 2026-09-05T15:34Z (polisher). 9 개 keeper 가 09-05T15:34–16:52Z 에 시작했고, 그 뒤 한 건도 지워지지 않았다.
- 09-11 하루에 붙은 witness: pr-updater 229, rondo 175, msx-retro-mania 252.

이 RFC 를 쓰며 다시 잰 값 (2026-09-12 13:04Z, `jq` 로 직접 읽음):

| keeper | revision | witnesses | bytes |
|---|---:|---:|---:|
| analyst | 3946 | 1966 | 2,004,344 |
| code-reviewer | 4984 | 2447 | 2,501,314 |
| critic | 3202 | 1594 | 1,624,351 |
| edgar.a.poe | 2443 | 1210 | 1,250,161 |
| geek-scout | 2285 | 1133 | 1,151,832 |
| goo-yang-bong | 2611 | 1283 | 1,311,393 |
| imp | 4 | 1 | 4,329 |
| jazz-developer | 3925 | 1944 | 1,989,907 |
| kidsnote-slack-context-collector | 88 | 43 | 46,152 |
| lane-smith | 3334 | 1658 | 1,688,891 |
| msx-retro-mania | 2305 | 1149 | 1,207,719 |
| polisher | 3415 | 1692 | 1,726,472 |
| pr-updater | 5515 | 2719 | 2,800,818 |
| rondo | 5361 | 2648 | 2,701,024 |
| sangsu | 8852 | 1658 | 1,901,212 |
| taskmaster | 11 | 3 | 8,466 |

합계 23,918,385 B, witness 23,148 건. 감사 스냅샷 뒤 9.5 시간 동안 pr-updater +87, rondo +67, code-reviewer +104.

같은 시각 모든 keeper 의 `event-queue-transitions-v8.jsonl` 은 0 B 였다.
전이 WAL 은 이미 있다. 투영이 끝나면 바로 비운다 (§1.3).

revision 과 witness 의 비:

- pr-updater 5515 / 2719 = 2.03, code-reviewer 4984 / 2447 = 2.04. 감사가 본 "revision ≈ 2 × witness" 와 같다.
- sangsu 8852 / 1658 = 5.34. sangsu 는 pending 192 건(그중 schedule_due 151) 이 쌓인 manual keeper 다.
  enqueue 도 revision 을 올리지만 witness 는 남기지 않는다. 그래서 "2 배" 는 전이만 일어나는 keeper 에서만 맞는다.
  이 값은 파일에서 읽은 것이고, enqueue 가 revision 을 올린다는 해석은 §2.2 측정으로 확인한다.

### 1.2 witness 한 줄의 모양

pr-updater 첫 행을 그대로 옮긴다 (13:04Z).

```json
{"transition_id":"pending-source-terminal-ack:turn-attempt-terminal:5496:0405de3c…c321540",
 "event_id":"keeper-event-queue-transition:pending-source-terminal-ack:turn-attempt-terminal:5496:0405de3c…c321540",
 "operator_operation_id":"turn-attempt-terminal:5496:0405de3c…c321540",
 "transition_ref":"997f198e…c061cb88",
 "source_ref":"0405de3c…c321540",
 "post_id":"p-6ae514c9acc9b2b149a9c6e0ee80e430",
 "source_kind":"board_attention","source_incarnation":5496,
 "disposition":{"kind":"turn_completed"}}
```

64-hex `source_ref` 가 네 번 들어 있다: `transition_id`, `event_id`, `operator_operation_id`, `source_ref`.
turn-terminal 계열에서는 세 id 가 `<접두사>:<incarnation>:<source_ref>` 로 만들어진다
(`keeper_event_queue_state.ml:797-799` `pending_transition_id`, `event_id_of_transition`).
운영자가 낸 cancel / transfer 의 `operator_operation_id` 는 운영자가 준 값이다. 유도할 수 없다.

### 1.3 지금의 쓰기 경로

전이 하나가 파일에 닿는 순서다. 함수 이름은 `lib/keeper_runtime/keeper_event_queue_persistence.ml` 기준.

1. commit — `commit_transition_unlocked_with` (:1092-1130).
   전이를 `transition_outbox` 에 넣고 WAL 에 한 줄 append, revision +1.
   이 시점에 스냅샷은 쓰지 않는다. `save_checkpoint` 는 no-op 이다 (:1189-1194, "The transition WAL is the commit record").
2. projection — `project_transition_outbox_result` (:1380-1400).
   reaction ledger 에 append 한 뒤 `State.mark_transition_projected` (`keeper_event_queue_state.ml:420-433`) 를 부른다.
   이 함수가 직전 `last_transition` 을 witness 로 접어 `projected_dispositions` 앞에 붙인다. 자르는 코드는 없다.
   revision +1, `save_state_unlocked` 가 스냅샷 전체를 다시 쓴다
   (`save_json_atomic_with` :152-166, `Yojson.Safe.pretty_to_string` 뒤 임시 파일 rename).
   그 다음 `compact_transition_wals_unlocked` 가 WAL 을 비운다.

그러니 전이 1 건 = WAL 1 줄 append + 스냅샷 전체 1 회 재기록 + WAL 비우기.
재기록 바이트는 그 시점의 파일 크기다. pr-updater 는 지금 2.8 MB 다.

### 1.4 읽는 쪽

`projected_dispositions` 를 읽는 자리는 다섯 곳이다.

| 읽는 곳 | 무엇을 찾나 | 언제 |
|---|---|---|
| `Keeper_event_queue_state.prior_disposition_by_operation_id` (:820-833) | 같은 `operator_operation_id` 의 앞선 처분 | cancel / transfer / ack 가 다시 들어올 때 (replay) |
| `Keeper_event_queue_state.ack_source_terminal` 의 witness arm (:1105-1145) | `source_ref` + `source_incarnation` + 종류가 같은 witness | 턴 종료 ack 가 다시 들어올 때. 같으면 `Transition_already_applied` |
| `Keeper_event_queue_state.validate` (:1950-1990) | transition_id / operation_id 중복 | 로드와 검증 때마다. `duplicate_by` 는 `String_set` 로 n log n |
| `Keeper_event_queue_persistence.replay_transition_wal` → `durable_matches_receipt` (:1221) | WAL 행이 이미 투영됐는지 | 부팅 replay |
| `Server_schedule_consumers.durable_occurrence_index` (:730-870) | occurrence_id 별 상태 (Pending / Transferred / Terminally_completed …) | 스케줄 occurrence 를 다시 넣기 전에 keeper 큐 전체를 인덱스로 만듦 |

다섯 곳 모두 "이미 처리했는가" 를 묻는다. 목록을 앞에서 뒤로 훑는 것 말고 다른 용도는 없다.

### 1.5 "6 GB/일" 은 어떻게 나온 수인가

R9 의 계산: 09-11 에 붙은 witness 수 × 2 × 현재 파일 크기.
pr-updater 229 × 2 × 2.75 MB ≈ 1.26 GB, rondo 0.92 GB, code-reviewer 0.68 GB, 16 keeper 합 6.0 GB.

가정이 둘 있다.

- (a) 전이마다 파일을 2 회 다시 쓴다. §1.3 대로라면 코드 경로는 1 회 재기록 + WAL 1 줄이다.
  revision 이 두 번 오르는 것과 파일이 두 번 써지는 것은 다르다. 이것이 측정으로 가장 먼저 확인할 항목이다.
- (b) 하루 동안 파일 크기가 일정하다. 실제로는 witness 마다 1 KB 씩 커진다.

이 RFC 는 6 GB 를 "추정" 으로만 인용한다. 실측값은 §2.2 가 만든다.

### 1.6 결정 5 의 배경 (Q6, S7)

Q6 (merged.md, VERIFIER 재측정 09-08..09-12): chat operation 이 keeper 의 턴 슬롯을 잡고 있는 동안 자율 작업이 밀린다.
`Keeper Owner deferred autonomous work: reason=turn_busy holder_lane=chat_operation` 899 줄, (keeper, holder_started_at) 으로 묶으면 154 건.
최장 293 분 (msx-retro-mania, 09-10T16:01Z 시작, 97 cycle). p50 2.6 분, p90 24.9 분. 61 분 넘는 건 한 건.
코드: `lib/keeper/keeper_owner.ml:845-863` (chat operation 이 `child_active` + `publish_turn_in_flight`), `:1294-1300` (자율 요청이 `Turn_busy`).
예산과 타임아웃이 없는 것은 정책이다 (`lib/server/server_routes_http_keeper_stream.ml:662-666`).

S7 (merged.md, 2026-09-12 03:29Z queue-snapshot): manual keeper sangsu 의 큐에 schedule_due 151 건.
'hourly board sweep' 70 건 + '빈정 탄약고 시간별 업데이트' 70 건, 한 시간에 하나씩. 가장 오래된 것 73 h. taskmaster 3 건 (51 h).
각 occurrence 가 자기 `post_id` 를 가지므로 큐에서는 아무것도 합쳐지지 않는다
(`lib/keeper_runtime/keeper_event_queue.ml:356-370` `stimulus_identity_equal`, Schedule_due 는 `post_id` 만 비교).
읽는 쪽은 이미 묶는다. `lib/keeper/keeper_unified_prompt.ml:812-817` `same_scheduled_wake_series` 가
(schedule_id, schedule_instance_id, payload_digest) 가 같은 행을 한 그룹으로 만들고 `occurrence_count`, `first_due_at`, `last_due_at` 을 보여준다.
큐에는 70 행, 프롬프트에는 1 행. 이 차이가 결정 5 의 대상이다.

## 2. 설계

### 2.1 지금의 계약 — producer → store → consumer → caller

이 절은 바꾸자는 것이 아니라 지금 있는 것을 타입으로 적은 것이다. §2.2 의 측정은 이 표의 화살표마다 숫자를 붙인다.

```ocaml
(* producer: witness 를 만드는 유일한 자리 *)
val Keeper_event_queue_state.mark_transition_projected
  : transition_id:string -> t -> (t, string) result
(* 직전 last_transition 을 witness_of_receipt 로 접어 projected_dispositions 앞에 붙인다.
   호출자: Keeper_event_queue_persistence.project_transition_outbox_result 하나. *)

(* store: 보관하는 자리 *)
type durable_store =
  | Snapshot of { path : string }        (* keepers/<k>/event-queue-v19.json — 전체 State, pretty JSON *)
  | Transition_wal of { path : string }  (* keepers/<k>/event-queue-transitions-v8.jsonl — commit 기록, 투영 뒤 비움 *)
(* witness 는 Snapshot 에만 있다. Transition_wal 에는 outbox 행만 있다. *)

(* consumer: witness 를 읽는 자리 — §1.4 의 다섯 곳 *)
type witness_reader =
  | Operation_replay        (* prior_disposition_by_operation_id *)
  | Terminal_ack_replay     (* ack_source_terminal 의 witness arm *)
  | Load_validate           (* validate: 중복 검사 *)
  | Wal_replay              (* durable_matches_receipt *)
  | Schedule_occurrence_index  (* server_schedule_consumers.durable_occurrence_index *)

(* caller: 각 reader 를 부르는 쪽 *)
type witness_caller =
  | Keeper_turn_intake        (* 턴 종료 ack — keeper_heartbeat_stimulus_intake *)
  | Hitl_delivery_replay      (* 부팅마다 gate/pending.json 의 delivery 를 다시 보냄 *)
  | Fusion_terminal_delivery
  | Operator_cancel_or_transfer  (* TUI / dashboard *)
  | Schedule_runner_dispatch  (* schedule_runner → server_schedule_consumers *)
  | Boot_replay
```

### 2.2 측정 계약

무엇을 셀지, 어디서 셀지, 얼마 동안 셀지를 닫힌 합으로 적는다. 항목 밖의 수치는 이 RFC 의 근거로 쓰지 않는다.

```ocaml
type sample_source =
  | Snapshot_file of { keeper : string }     (* keepers/<k>/event-queue-v19.json *)
  | Transition_wal_file of { keeper : string }  (* keepers/<k>/event-queue-transitions-v8.jsonl *)
  | System_log of { day_utc : string }       (* logs/system_log_<day>.jsonl *)
  | Schedule_store                            (* schedules/ 의 wakes, signal seen 목록 *)

type measure =
  | Snapshot_bytes                 (* stat 크기 *)
  | Witness_count                  (* projected_dispositions 길이 *)
  | Revision                       (* .revision *)
  | Pending_count                  (* .pending 길이 *)
  | Witness_by_kind                (* source_kind 14 종 × disposition 6 종 분포 *)
  | Witness_age_sec                (* now − applied_at_unix, kind 별 분포 *)
  | Incarnations_per_source_ref    (* source_ref 하나에 witness 몇 건, incarnation 몇 종 *)
  | Bytes_written_per_projection   (* 투영 1 건이 쓴 바이트 = 그 시점 Snapshot_bytes. Δrevision 과 mtime 변화로 셈 *)
  | Projections_per_revision       (* Δrevision 당 실제 스냅샷 재기록 횟수 — §1.5 (a) 의 판정 *)
  | Load_validate_wall_ms          (* validate_state_read_only_result 1 회 벽시계, p50 / p95 *)
  | Replay_hit of witness_reader   (* reader 별로 "이미 적용됨" 을 돌려준 횟수 *)
```

셈 방법:

- `Snapshot_bytes`, `Witness_count`, `Revision`, `Pending_count`: 10 분마다 16 파일을 `jq` 와 `stat` 으로 읽는다. 읽기만 한다. 서버 프로세스를 거치지 않는다.
- `Projections_per_revision`: 같은 표본에서 Δrevision 과 파일 mtime 변화 횟수를 나란히 둔다. 10 분 안에 revision 이 2 오르고 mtime 이 1 번 바뀌면 (a) 는 틀린 가정이다.
- `Bytes_written_per_projection`: mtime 이 바뀐 표본마다 그 시점 크기를 더한다. 하루 합이 "실측 GB/일" 이다.
- `Witness_by_kind`, `Witness_age_sec`, `Incarnations_per_source_ref`: 하루 한 번 스냅샷 전체를 읽어 분포를 낸다.
- `Load_validate_wall_ms`: 측정 브랜치에 읽기 전용 프로브를 둔다. `Keeper_event_queue_persistence.validate_state_read_only_result` 를 파일 복사본에 20 회 돌려 p50 / p95 를 적는다.
  2.8 MB 실물 하나와 witness 를 4 배로 늘린 합성 파일(라벨 "synthetic") 하나. 프로브는 측정 브랜치와 함께 지운다.
- `Replay_hit`: 있는 로그로 센다. `Hitl_delivery_replay` 는 `hitl resolution committed approval=… signal=` 줄,
  `Schedule_runner_dispatch` 는 `durable_occurrence_index` 가 `already_acked` / `already_failed` / `already_cancelled` 로 답한 줄.
  `Terminal_ack_replay` 와 `Operation_replay` 는 지금 로그 줄이 없다. 측정 브랜치에서 `Transition_already_applied` 반환 자리에 DEBUG 한 줄을 붙이고, 브랜치와 함께 지운다.
  이 줄은 제품 코드가 아니다. main 에 올리지 않는다.

기간: 7 일 연속, UTC. 시작 시각과 끝 시각을 결과 문서 첫 줄에 적는다.
하루로는 부족하다. 재시작이 하루 평균 6 회(09-08..09-11 은 80 회) 있고, 부팅 replay 가 `Replay_hit` 의 큰 부분이다. 일주일이면 시간별 스케줄 168 회와 일일 스케줄 7 회를 다 본다.

결과 파일: `docs/audits/<YYYY-MM-DD>-event-queue-witness-measure.md`. 원본 표본은 `.masc/evidence/witness-measure-<start>/` 에 jsonl 로 둔다.

### 2.3 측정이 답해야 하는 질문

답이 나오지 않은 질문이 하나라도 있으면 §2.4 로 가지 않는다.

**Q1. 누가 `projected_dispositions` 를 읽고, 각자의 멱등성 창은 얼마인가.**
reader 다섯 곳마다 "이 witness 를 마지막으로 읽을 수 있는 시점" 을 적는다. 예상되는 답:

| reader | 창이 닫히는 조건 (durable 근거) |
|---|---|
| `Wal_replay` | WAL 이 비워진 뒤. 지금은 투영 직후 → 창은 몇 초 |
| `Terminal_ack_replay` | 그 턴의 reaction ledger 행이 남은 뒤. 부팅 replay 가 한 번 더 물을 수 있음 |
| `Operation_replay` | 운영자 operation 이 같은 id 로 다시 오지 않을 때. 운영자 재시도 창은 지금 정해져 있지 않음 |
| `Schedule_occurrence_index` | schedule store 의 wake 가 terminal 이고 runner 의 seen 목록에 occurrence_id 가 있을 때 (`schedule_runner.ml:225-250` `append_new_signals`) |
| `Hitl_delivery_replay` | `gate/pending.json` 의 delivery 가 consumed 로 바뀔 때. S1 은 52 회 부팅 동안 안 바뀜 → 지금은 창이 닫히지 않음 |

측정은 `Replay_hit` 으로 이 표의 "예상" 을 "실측" 으로 바꾼다. 특히 가장 오래된 hit 의 witness 나이가 답이다.

**Q2. witness 를 source incarnation 단위로 끊을 수 있는가.**
witness 는 `source_incarnation` 을 갖고, `Terminal_ack_replay` 는 `source_ref` 와 `source_incarnation` 이 둘 다 같을 때만 "이미 적용됨" 을 돌려준다 (`keeper_event_queue_state.ml:1113-1114`).
그러니 같은 `source_ref` 에서 더 새 incarnation 의 witness 가 있을 때, 옛 incarnation 의 witness 를 읽는 replay 가 실제로 오는가가 질문이다.
`Incarnations_per_source_ref` 가 "source_ref 하나에 incarnation 2 종 이상" 인 건수를 세고, `Replay_hit` 이 그중 옛 incarnation 을 맞춘 횟수를 센다.
0 이면 incarnation 단위로 끊을 수 있다. 0 이 아니면 어떤 caller 가 옛 incarnation 으로 다시 오는지를 적고, 그 caller 를 먼저 고친다.

**Q3. 하루에 실제로 몇 바이트를 쓰는가.**
`Bytes_written_per_projection` 의 7 일 합 ÷ 7. 6 GB 추정과 나란히 적는다.

**Q4. 로드와 검증에 얼마나 걸리는가.**
`Load_validate_wall_ms` p95. 2.8 MB 에서의 값과 합성 10 MB 에서의 값. RFC-0380 이 말하는 "턴 진입 지연" 에 이 값이 보이는 크기인지 적는다.

**Q5. keeper 를 넘어 읽는 곳이 있는가.**
`server_schedule_consumers.durable_occurrence_index` 는 keeper 하나의 파일만 읽는다. fleet 단위로 witness 를 모으는 코드가 있으면 §2.4 의 "keeper 별 파일" 가정이 깨진다. `rg projected_dispositions lib/` 전수로 답한다.

### 2.4 조건부 설계 — Q2 가 "끊을 수 있다" 일 때만

이 절은 후보다. 측정 전에 구현하지 않는다.

**보관 위치를 나눈다.**

```ocaml
(* 스냅샷 (v20, 하드컷) — witness 목록이 빠진다 *)
type t =
  { revision : int64
  ; pending_entries : pending_selection list
  ; last_transition : transition_receipt option
  ; transition_outbox : outbox_entry list
  ; accepted_transfer_projections : accepted_transfer list
  }

(* witness 원장 — keeper 별 append-only jsonl, 한 행이 witness 하나 *)
type witness_row =
  { revision : int64                      (* 이 witness 를 쓴 투영의 revision. 행 순서의 근거 *)
  ; applied_at : float
  ; source_ref : string                   (* 64-hex 한 번만 *)
  ; source_incarnation : int64
  ; post_id : string
  ; urgency : Keeper_event_queue.urgency
  ; source_arrived_at : float
  ; source_kind : projected_source_kind
  ; kind : projected_disposition_kind
  ; operation : witness_operation
  }

and witness_operation =
  | Derived_from_source                   (* turn-terminal 계열: id 셋이 source_ref 와 incarnation 에서 나온다 *)
  | Operator_supplied of { operator_operation_id : string }  (* cancel / transfer: 운영자가 준 id 를 그대로 둔다 *)
```

`transition_id`, `event_id`, `transition_ref` 는 파일에 쓰지 않고 읽을 때 다시 만든다. §1.2 의 유도 규칙이 코드에 이미 있다.
행 하나가 지금의 1,020 B 에서 64-hex 셋과 접두사 문자열이 빠진 크기가 된다. 정확한 값은 구현 PR 이 실물로 잰다.

**commit 확인, 순서, 찢긴 쓰기, 체크포인트, 보관 — Codex 가 요구한 다섯 가지.**

- commit 확인: 투영은 (1) witness 행 append + fsync, (2) 스냅샷 rename, (3) WAL 비우기 순서다.
  (1) 이 끝나기 전에는 스냅샷의 `last_transition` 이 아직 그 전이를 들고 있다. (1) 과 (2) 사이에서 죽으면 같은 사실이 두 곳에 있다.
  로드는 "원장 마지막 행 = 스냅샷 `last_transition`" 을 같은 사실로 읽는다. 지금 `durable_matches_receipt` (:1221) 가 하는 일과 같다.
- 순서: 행의 `revision` 은 단조 증가여야 한다. 로드가 감소를 보면 `Witness_ledger_out_of_order of { at_row : int }` 로 거부한다. 고쳐 읽지 않는다.
- 찢긴 쓰기: 마지막 행이 JSON 으로 안 닫히면 `Witness_ledger_torn of { byte_offset : int }` 로 거부한다. 자동으로 잘라내지 않는다.
  잘라내는 것은 운영자 명령 하나로만 한다. 그 명령은 잘라낸 바이트를 옆 파일에 남긴다 (failure keeps evidence).
- 체크포인트 원자성: 스냅샷은 지금처럼 임시 파일 + rename 이다. 원장은 append 만 한다. 둘을 한 트랜잭션으로 묶지 않는다. 대신 위 (1)→(2)→(3) 순서와 로드 규칙이 어느 지점에서 죽어도 사실이 하나만 남게 한다.
- 보관: 시간이나 개수로 자르지 않는다 (헌법: no caps). witness 는 그것을 읽을 마지막 reader 가 자기 durable 상태로 "다시 안 읽는다" 를 남긴 뒤에만 지운다.

```ocaml
type retirement_evidence =
  | Wal_retired                                  (* Wal_replay: WAL 이 비워짐 *)
  | Reaction_recorded of { turn_id : string }    (* Terminal_ack_replay: reaction ledger 행 *)
  | Hitl_delivery_consumed of { approval_id : string }  (* Hitl_delivery_replay: gate/pending.json consumed *)
  | Schedule_occurrence_terminal of { occurrence_id : string }  (* Schedule_occurrence_index *)
  | Operation_settled of { operator_operation_id : string }     (* Operation_replay *)
```

정리(compaction)는 `source_incarnation` 단위다. 같은 `source_ref` 에서 가장 새 incarnation 보다 오래된 행은, 그 행의 모든 reader 가 위 근거를 갖고 있을 때 새 원장 파일로 옮겨 쓰며 뺀다. 옮겨 쓰기는 append-only 파일을 새로 만들고 rename 한다.
근거가 없는 행은 남는다. S1 처럼 delivery 가 영영 consumed 가 안 되면 그 witness 는 영영 남는다. 그것은 이 RFC 의 버그가 아니라 RFC-0448 이 다룰 HITL delivery 의 버그다. 원장이 그 사실을 보여준다.

**로드 결과는 닫힌 합이다.**

```ocaml
type witness_ledger_load =
  | Loaded of { rows : int; oldest_applied_at : float option }
  | Absent                                       (* 파일 없음 — fresh state *)
  | Witness_ledger_torn of { byte_offset : int }
  | Witness_ledger_out_of_order of { at_row : int }
  | Witness_ledger_schema_mismatch of { actual : string; expected : string }
```

`Absent` 는 v20 하드컷 직후에만 정상이다. v19 파일을 읽는 호환 reader 는 만들지 않는다. 운영자가 리셋 명령으로 v19 를 지우고 시작한다. 절차는 구현 PR 이 `docs/` 에 적는다.

### 2.5 결정 5 — 미배달 interval occurrence 합치기

결정 5: "chat operation 에 누적 예산을 두지 않는다. 점유와 미룸을 보여주고, 배달되지 않은 interval occurrence 를 합친다."
Codex 는 동의하되 다섯 가지를 못 박으라고 했다. 순서대로 답한다.

**2.5.1 대상 occurrence 와 합치는 키.**

```ocaml
type coalescing_key =
  { keeper_name : string
  ; schedule_id : string
  ; schedule_instance_id : string   (* 스케줄 revision. update 마다 새 값 — schedule_domain.ml:93-94 *)
  ; payload_digest : string
  }

type coalescing_eligibility =
  | Eligible of coalescing_key
  | Not_interval                (* One_shot, Daily, Cron *)
  | Not_schedule_due            (* Schedule_due 가 아닌 모든 payload *)
  | Held_by_live_turn           (* 지금 도는 턴의 selection 에 들어 있음 *)
```

대상은 `Schedule_due` 이고 recurrence 가 `Interval` 인 pending 행뿐이다. 키는 읽기 쪽이 이미 쓰는 `same_scheduled_wake_series` 와 같다.
`schedule_instance_id` 가 키에 있으므로 편집 전 occurrence 와 편집 후 occurrence 는 절대 합쳐지지 않는다.

제외 — 다음은 하나하나가 다른 상대가 기다리는 별개의 의무라 합치지 않는다:
`Hitl_resolved`, `Connector_attention`, `Fusion_completed`, `Ask_answered`, `Task_outcome`, `Task_cancelled`, `Delegate_completed`, `Composition_completed`, `Completion_authority_rejected`, `Workspace_message`, `Board_signal`, `Board_attention`, `Bootstrap`.
`Daily` 와 `Cron` 도 뺀다 (`schedule_domain.ml:28-40` 의 recurrence 네 종 중 `Interval` 하나만). 달력 시각에는 뜻이 있을 수 있다(매일 09:00 보고). interval 만 "다음 것이 오면 앞 것은 같은 일" 이라 말할 수 있다. daily 와 cron 을 넣을지는 별도 결정이다.

**2.5.2 어느 occurrence 가 남고, 지난 것은 어떻게 남기나.**

`due_at` 이 가장 큰 occurrence 가 남는다. 이유: schedule store 는 `update_latest_running_wake` (`schedule_store.ml:614`) 로 schedule_id 당 가장 최근 wake 를 든다. 남는 행의 ack 가 그 wake 를 닫아야 한다.

지난 occurrence 는 지우지 않는다. 큐 전이 `Supersede_accepted` 로 처분하고 witness 를 남긴다.

```ocaml
type projected_disposition_kind =
  | …기존 6 종…
  | Projected_superseded of { successor_post_id : string }   (* 어느 occurrence 가 대신했는가 *)
```

witness 는 지난 occurrence 의 원래 `post_id`(= occurrence_id), 원래 `source_arrived_at`, 원래 `due_at` 을 그대로 든다. 과거 배달 기록(schedule store 의 wake 행, reaction ledger) 은 고쳐 쓰지 않는다.
schedule store 쪽은 `wake_status` 에 `Wake_superseded of { successor_occurrence_id : string }` 를 더한다. `Wake_failed` 를 빌려 쓰지 않는다.

**2.5.3 claim, 배달과 원자적으로.**

합치기는 별도 sweeper 가 아니다. `server_schedule_consumers` 가 새 occurrence 를 enqueue 하는 그 트랜잭션 안에서 한다.
`Owner_lock.with_durable_lock` 아래에서 (1) 같은 키의 pending 행을 찾고, (2) 지금 도는 턴의 selection 에 든 행은 `Held_by_live_turn` 으로 건너뛰고, (3) 나머지에 `Supersede_accepted` 를 commit 하고, (4) 새 occurrence 를 enqueue 한다. 넷이 한 WAL 행과 한 스냅샷 재기록이다.

그래서:
- 도는 턴이 든 occurrence 는 대신될 수 없다. 그 턴의 ack 는 자기 `post_id` 로 온다.
- 대신된 occurrence 의 ack 가 뒤늦게 오면 `Terminal_ack_replay` 가 `Projected_superseded` witness 를 찾아 `Transition_already_applied` 를 돌려준다. 두 번 실행되지 않는다.
- 후임 occurrence 의 `post_id` 로 선임을 ack 할 길은 없다. `post_id` 가 다르다.

**2.5.4 manual, pause, 편집, 삭제, 재시작.**

| 상황 | 동작 |
|---|---|
| manual keeper (RFC-0448) | 0448 이 "manual keeper 도 occurrence 를 받는다" 로 정하면, 키당 pending 1 행만 남는다. sangsu 의 70 + 70 은 2 행이 된다. 0448 이 "생성 때 거부" 로 정하면 합칠 것이 없다 |
| paused keeper | 턴이 없으니 enqueue 때 합치기만 계속된다. resume 하면 키당 현재 occurrence 1 건이 그대로 배달된다. 운영자 선택은 필요 없다. 지난 것은 witness 로 보인다 |
| 스케줄 편집 | `schedule_instance_id` 가 바뀐다. 옛 instance 의 미배달 행은 그대로 남아 자기들끼리만 합쳐지고 별도 그룹으로 배달된다. 편집이 keeper 큐를 건드리지 않는다. 운영자는 두 그룹을 본다 |
| 스케줄 삭제(cancel) | 지금 `cancel_request` (`schedule_store.ml:684-712`) 는 schedule store 의 wake 행만 settle 한다. keeper 큐의 pending occurrence 를 누가 처분하는지는 이 RFC 를 쓰며 확인하지 못했다 (확인 필요, 구현 PR 이 먼저 답한다). 정하는 것: cancel 은 같은 키의 pending 행에 `Cancel_accepted` 를 commit 한다. 이미 대신된 행은 이미 witness 라 건드릴 것이 없다 |
| 재시작 | `Supersede_accepted` 도 다른 전이처럼 WAL 에 commit 된다. 부팅 replay 는 다른 전이와 같다. runner 의 seen 목록이 같은 occurrence 를 다시 내지 않는다 |

**2.5.5 무엇을 보여주고, 무엇을 만들지 않나.**

이미 있는 것: fleet health JSON 이 `turn: { lane, started_at_unix }` 를 낸다 (`server_routes_http_runtime_health_fleet.ml:72-86`). 로그 한 줄이 `holder_lane`, `holder_started_at` 을 찍는다 (`keeper_owner.ml:374`).

더 보이게 할 것 (keeper 행, dashboard keeper JSON, TUI Keeper 탭):

```ocaml
type lane_occupancy =
  { holder : turn_lane            (* Chat_operation | Autonomous | … 기존 합 *)
  ; started_at : float
  ; deferred_autonomous_cycles : int   (* holder 가 시작한 뒤 자율 작업이 밀린 cycle 수. 상태이지 알람이 아님 *)
  }

type coalesced_pending =
  { key : coalescing_key
  ; occurrence_count : int        (* 대신된 것 포함 *)
  ; first_due_at : float
  ; current_due_at : float
  }

(* next actor 는 RFC-0445 의 합타입을 그대로 쓴다. 여기서 새 합을 만들지 않는다. *)
```

만들지 않는 것: 점유 시간 상한, 예산, 시간이 지나면 끊는 게이트. 293 분 점유는 보이게 되지만 끊기지 않는다.
협력적 양보나 공정성(예: 도구 경계에서 lane 을 넘기기)은 별도 RFC 다. 그 RFC 도 경과 시간을 종료 조건으로 쓰지 않는다.

### 2.6 표면

| 표면 | 지금 | 이 RFC 뒤 |
|---|---|---|
| `keepers/<k>/event-queue-v19.json` | witness 전부 포함, 전이마다 전체 재기록 | (§2.4 조건부) v20: witness 없음. 크기는 pending 에 비례 |
| `keepers/<k>/event-queue-witnesses-v1.jsonl` | 없음 | (§2.4 조건부) append-only, incarnation 단위 정리 |
| `docs/audits/<date>-event-queue-witness-measure.md` | 없음 | 7 일 실측. Q1–Q5 의 답 |
| TUI Keeper 탭, dashboard keeper 행 | lane 점유는 로그에만 | `lane_occupancy`, `coalesced_pending`, next actor |
| schedule list / TUI Schedules | wake 가 running / succeeded / failed | `superseded` 가 후임 id 와 함께 보임 |
| 로그 | `deferred autonomous work` INFO 899 줄 | 그대로. 상태가 표면에 있으니 줄을 늘리지 않는다 |

## 3. 판정 기준

측정 단계:

- [ ] 7 일 표본이 빠짐없이 있다. 10 분 간격 × 16 keeper. 빠진 구간은 시각과 함께 적혀 있다.
- [ ] `Projections_per_revision` 이 (a) 가정을 판정했다. 1 회인지 2 회인지 숫자로.
- [ ] Q3 실측 GB/일 이 6 GB 추정과 나란히 적혀 있다.
- [ ] Q2 의 "옛 incarnation replay hit" 수가 0 인지 아닌지 적혀 있다. 0 이 아니면 caller 이름이 있다.
- [ ] Q1 표의 다섯 reader 모두에 실측 최장 창이 있다.
- [ ] 측정 브랜치의 프로브와 DEBUG 줄이 main 에 없다.

§2.4 구현 단계 (Q2 가 0 일 때만):

- [ ] v19 를 읽는 코드가 없다. `rg "event-queue-v19" lib/` = 0.
- [ ] `witness_ledger_load` 다섯 arm 모두에 테스트가 있다. torn 과 out_of_order 는 파일을 실제로 망가뜨려 만든다.
- [ ] 전이 1 건의 스냅샷 재기록 바이트가 pending 크기에만 비례한다. witness 1,000 건을 넣은 keeper 와 0 건 keeper 의 재기록 크기가 같다.
- [ ] `retirement_evidence` 없는 행은 정리 뒤에도 남아 있다. 테스트가 S1 모양(consumed 안 된 delivery) 을 만들어 확인한다.
- [ ] 같은 `operator_operation_id` 의 cancel 을 정리 전과 후에 다시 보내면 둘 다 `Transition_already_applied` 다.

§2.5 구현 단계:

- [ ] 같은 키 occurrence 세 건을 넣으면 pending 1 행, `Projected_superseded` witness 2 건이고, 둘의 `post_id` 와 `due_at` 은 원래 값이다.
- [ ] 도는 턴이 든 occurrence 는 대신되지 않는다. 테스트가 selection 을 잡은 채 새 occurrence 를 넣는다.
- [ ] 대신된 occurrence 의 ack 를 보내면 `Transition_already_applied`, 실행 0 회.
- [ ] `Cron` 과 `One_shot` 은 `Not_interval`. HITL / connector / fusion 은 `Not_schedule_due`.
- [ ] 편집 뒤 옛 instance 행과 새 instance 행이 서로 합쳐지지 않는다.
- [ ] 코드 어디에도 점유 시간으로 lane 을 끊는 분기가 없다. `rg "holder_started_at" lib/` 의 결과가 표시와 로그뿐이다.

## 4. 단계

1. 측정 (이 RFC 머지 직후, 7 일). 읽기 전용 스크립트 `scripts/measure-event-queue-witness.sh` 와 측정 브랜치의 프로브. 결과는 `docs/audits/`.
2. 판정. §2.3 Q1–Q5 의 답을 이 문서 §6 에 링크로 붙이고 `updated` 를 올린다. Q2 가 0 이 아니면 그 caller 를 고치는 별도 PR 이 먼저다.
3. §2.5 합치기. 측정과 독립이다. RFC-0448 의 결정이 먼저 나야 manual keeper 행의 뜻이 정해지므로 0448 뒤에 한다. `Supersede_accepted` 전이, `Projected_superseded` witness, `Wake_superseded`, 표면 셋.
4. §2.4 witness 원장 (조건부). v20 하드컷, 원장 파일, 로드 합, incarnation 정리, 리셋 절차 문서.
5. 닫기. 실측 GB/일 을 전후로 적고 `Implemented` 로 바꾼다.

## 5. 반론과 답

**"파일이 커지니 WAL 로 옮기면 된다. 왜 일주일을 재나."** (Codex `.missing`)
커진다는 사실은 알고 있다. 모르는 것은 누가 어느 witness 를 얼마나 오래 필요로 하는가다. 그걸 모르고 옮기면 정리 규칙을 정할 수 없고, 정리 없는 WAL 은 파일 이름만 바뀐 같은 문제다. 일주일은 재시작과 시간별·일일 스케줄을 다 보는 최소 길이다.

**"6 GB/일 이 맞든 틀리든 큰 수다."**
그래서 잰다. 코드 경로는 전이당 재기록 1 회라 3 GB 쪽일 수 있고, 파일이 하루 1 KB × 250 씩 커지니 더 클 수도 있다. 추정을 근거로 durable 계약을 바꾸지 않는다.

**"witness WAL 에 commit 확인, 순서, 찢긴 쓰기, 체크포인트 원자성, 보관이 없다."** (Codex `.missing` 첫 항목)
§2.4 에 다섯 항목을 따로 적었다. 보관만 요약하면: 시간·개수 상한 없음, reader 가 남긴 `retirement_evidence` 로만 지운다.

**"합쳐도 chat 이 lane 을 잡고 있는 동안 진행은 안 된다."** (Codex 결정 5 비판)
맞다. 합치기의 목표는 진행이 아니라 backlog 다. sangsu 의 151 행이 활성화 첫 턴에서 만료된 sweep 70 건에 예산을 쓰는 일을 막는다. 진행은 점유를 보이게 하는 것까지가 이 RFC 다. 끊는 것은 정책상 하지 않는다.

**"interval 이라도 occurrence 가 서로 바꿔 쓸 수 없는 일이 있다."** (Codex 결정 5 비판)
그래서 키에 `payload_digest` 와 `schedule_instance_id` 가 있다. payload 가 다르면 다른 키다. cron 은 뺐다. 그래도 남는 경우는 스케줄 정의가 interval 을 잘못 고른 것이고, 그건 스케줄을 cron 으로 바꿔 답한다.

**"witness 를 시간으로 자르면 간단하다."**
헌법이 cap 과 cooldown 을 금한다. 그리고 S1 이 보여주듯 52 회 부팅 동안 같은 delivery 가 다시 온다. 30 일로 자르면 31 일째 replay 가 두 번 실행된다. 근거 없는 삭제는 하지 않는다.

**"pretty JSON 을 compact 로만 바꿔도 13% 준다."**
1,020 → 886 B. 줄지만 문제의 모양이 같다. 측정 뒤 §2.4 로 가면 어차피 형식이 바뀐다. 지금 따로 하지 않는다.

**"transition WAL 이 이미 있는데 왜 또 파일을 만드나."**
전이 WAL 은 commit 기록이고 투영 뒤 비운다. witness 는 투영 뒤에 남아야 하는 것이다. 수명이 다르다. 한 파일에 두면 지금처럼 "비울 수 없는 파일" 이 된다.

**"측정 브랜치의 DEBUG 줄은 telemetry-as-fix 아닌가."**
main 에 안 올린다. 브랜치와 함께 사라진다. 제품 코드에 counter 를 더하는 것과 다르다.

## 6. 근거

감사 자료 (`/Users/dancer/me/.masc/evidence/audit-adversarial-20260912/`):

- `merged.md` R9 — witness 원장 (16 파일 23,232,137 B, witness 0/3/35/1,052–2,632, 2026-09-12 03:29Z). VERIFIER 재측정 포함.
- `merged.md` Q6 — chat operation 점유 (899 줄, 154 holder, 최장 293 분, 09-08..09-12).
- `merged.md` S7 — sangsu schedule_due 151 건 (70 + 70, 최장 73 h), taskmaster 3 건.
- `queue-snapshot.md` §projected_dispositions per keeper — keeper 별 n 과 file_bytes.
- `synthesis-adversarial.md` §5 — "RFC 필요: R9 witness WAL".
- `codex-roadmap.json` `.missing[0]` (commit ack / ordering / torn-write / checkpoint atomicity / retention), `.missing[2]` (producer / persistence owner / consumer / required history 먼저, 6 GB 는 추정), `.decision_critiques[4].rfc_must_pin_down` (결정 5 의 다섯 항목), `.rfc_order[6]`.
- 이 RFC 의 재측정: 2026-09-12 13:04Z, `jq`/`stat` 직접 읽기 (§1.1 표).

코드 (`/Users/dancer/me/workspace/yousleepwhen/masc`, HEAD e763050689):

- `lib/keeper_runtime/keeper_event_queue_state.ml` — `mark_transition_projected` :420-433, `witness_of_receipt` :307-323, `prior_disposition_by_operation_id` :820-833, ack witness arm :1105-1145, `validate` / `duplicate_by` :1909-1990, `witness_to_yojson` 필드 목록.
- `lib/keeper_runtime/keeper_event_queue_persistence.ml` — `save_json_atomic_with` :152-166, `commit_transition_unlocked_with` :1092-1130, `commit_transition_unlocked` :1187-1194, `project_transition_outbox_result` :1373-1400, `replay_wal_unlocked` :516-530.
- `lib/keeper_runtime/keeper_event_queue_schema.ml` — `snapshot_filename` :33 `event-queue-v19.json`, `transition_wal_filename` :39 `event-queue-transitions-v8.jsonl`.
- `lib/keeper_runtime/keeper_event_queue.ml` — `stimulus_identity_equal` :356-370.
- `lib/server/server_schedule_consumers.ml` — `durable_occurrence_index` :730, projected_dispositions 인덱스 :865, `durable_occurrence_state` :619-630.
- `lib/schedule/schedule_runner.ml` — `occurrence_id` :166-172, `append_new_signals` seen 목록 :225-250.
- `lib/schedule/schedule_domain.ml` — recurrence `One_shot` / `Interval` / `Daily` / `Cron` :28-40, instance id 는 update 마다 새 값 :93-94.
- `lib/schedule/schedule_store.ml` — `update_latest_running_wake` :614, `update_request` :665, `cancel_request` :684.
- `lib/keeper/keeper_unified_prompt.ml` — `same_scheduled_wake_series` :812-817, `group_scheduled_wake_events` :821-870.
- `lib/keeper/keeper_owner.ml` — `turn_in_flight` :43-46, chat operation claim :845-863, `Turn_busy` :1294-1300, 로그 :374.
- `lib/server/server_routes_http_runtime_health_fleet.ml` — `turn: { lane, started_at_unix }` :72-86.

관련 RFC:

- RFC-0448 (manual-keeper-durable-demand) — manual keeper 가 occurrence 를 받는지 거부하는지. §2.5.4 의 첫 행이 그 결정에 걸려 있다.
- RFC-0445 (next-actor-sum) — §2.5.5 의 next actor 표시는 이 합타입을 쓴다.
- RFC-0380 — 큐 로드 시간이 턴 진입 지연에 보이는지 (Q4).
- RFC-event-queue-admit-all-ready — 같은 `schedule_id` 의 occurrence 를 턴 컨텍스트에서 한 행으로 투영한다는 §0 셋째 항목. 이 RFC 의 §2.5 는 그 읽기 쪽 묶음을 쓰기 쪽으로 옮긴다.
