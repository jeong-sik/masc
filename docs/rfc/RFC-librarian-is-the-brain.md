---
rfc: "librarian-is-the-brain"
title: "Keeper 가 몸이면 Librarian 은 뇌다 — 자기 루프로 돌고, 끝난 턴을 빠짐없이 순서대로 읽는다"
status: Draft
created: 2026-09-18
updated: 2026-09-18
author: vincent
supersedes: []
superseded_by: null
related: ["keeper-context-window-in-tokens", "memory-os-bounded-context-and-librarian-curator", "0456", "0363"]
implementation_prs: []
---

# RFC: Keeper 가 몸이면 Librarian 은 뇌다

- 상태: Draft
- 작성: 2026-09-18. 코드는 origin/main `84fb520c34`, 실측은 같은 날 라이브 `<base-path>/.masc`.
- 관련: 창 RFC(`keeper-context-window-in-tokens`) §13 개정 Draft #37008, Memory OS RFC(`memory-os-bounded-context-and-librarian-curator`), RFC-0456, RFC-0363, 이슈 #37004·#36979

## 1. 결정 (운영자, 2026-09-18)

1. **Keeper 가 몸이면 Librarian 은 뇌다.** 몸은 세상에서 움직이고, 뇌는 몸이 겪은 것을 수시로 읽어 기억과 맥락을 정리한다. 특정 주기나 조건표로 도는 부업이 아니다. 몸이 뇌에게 일을 시키지 않는다.
2. 흡수 지점을 지나간 턴에서 살아남는 것은 **지식(facts)과 하던 일**이다.
3. Librarian 이 하는 일을 **셋으로 나눈다**: ① 턴 읽기 ② 기억 접기 ③ 받은 일 정리.
4. "수시로"는 세 가지를 뜻한다 — (가) 자기 루프로 돈다 (나) 턴 도중에도 읽는다 (다) 한가할 때도 정리한다. 셋 다 목표이고 **하나씩** 넣는다. 이 RFC 가 이행까지 다루는 범위는 (가)이고, (나)(다)는 §7 에 목표 모양으로 적는다.
5. TypeSafe Jev 같은 판단 전용 모델은 **하네스의 채점자**로 먼저 쓴다. 운영 경로에는 넣지 않는다.

이 RFC 는 창 RFC §13.7 의 선행 조건("Librarian 이 어디까지 흡수했나를 물어볼 자리")을 채운다. 창 조립이 그 위치를 쓰는 일은 창 RFC 의 몫이다.

## 2. 지금 무엇이 틀렸나

### 2.1 코드

| # | 결함 | 근거 |
|---|---|---|
| D0 | 몸이 뇌를 부린다. Keeper 턴 끝 경로가 Librarian 입력을 만들어 큐에 넣는다. Keeper 재기동은 앞선 Librarian 작업이 끝나길 기다린다. 서버 재시작에 끊긴 회차는 이어지지 않는다 | `keeper_agent_run_post_turn_memory.ml` `run`, `keeper_memory_lane.ml` `begin_librarian_lifecycle`, `exact_lane_run_registry.ml` `restart_reason` |
| D1 | 읽은 위치가 없다. 매번 "맨 뒤 72개 메시지"만 읽는다. 72 는 서로 상관없는 두 설정값의 곱이다(24 × 3) | `keeper_librarian_runtime.ml` `prompt_max_messages`, `select_recent_messages` |
| D2 | 3턴마다 돌고, 실패하면 3턴 더 밀린다 | 같은 파일 `cadence_step`, `cadence_record_attempt` |
| D3 | 호출 한 번이 다 한다 — 대화 읽기, facts 전체 읽기, 쓰기, 접기, 받은 일 정리. 출력 세 칸이 전부 필수다 | `config/prompts/librarian.md`, `keeper_structured_output_schema.ml` `librarian_current_output_schema` |
| D4 | 프롬프트가 "오래 쓸 지식"만 남기라고 한다. 턴 진행과 현재 상태는 저장하지 말라고 한다. 그래서 지점을 지나간 "하던 일"은 어디에도 남지 않는다 | `config/prompts/librarian.md` §남길 지식과 증거 |
| D5 | "이 턴이 이력의 어디까지인가"가 저장되지 않는다. 턴이 시작할 때의 길이는 메모리에만 있다. 프롬프트의 `turn=%d` 는 턴 번호가 아니라 메시지 순번이다 | `keeper_turn_driver_try_provider.ml` `initial_message_index`, `keeper_librarian.ml` `format_messages_for_prompt` |
| D6 | 도구 결과와 호출은 `[... omitted]` 로만 받고 thinking 은 빠진다. 공식 클라이언트 턴은 assistant 메시지 1개만 받는다 | `keeper_librarian.ml` `text_of_content`, `keeper_agent_run_finalize_response.ml` `librarian_messages` |
| D7 | 멈춰도 보이지 않는다 | §2.2 |
| D8 | 첫 슬롯이 Timeout·Network_error·Context_overflow 로 실패하면 다음 슬롯으로 넘어가지 않고 회차가 끝난다 | `exact_output.ml` `execution_failure_may_advance` (#36979 미해결분) |

이미 고쳐진 것은 다시 설계하지 않는다: 점호 제거와 `absorbs`(RFC-0456, #36936·#36937·#36948). 라이브에서 code-reviewer 의 facts 가 378개(09-16)에서 231개(09-18)로 줄었고 흡수 기록은 91건이다.

### 2.2 라이브 실측 (2026-09-17 00:00Z ~ 09-18 07:08Z, 31.1시간)

출처는 `exact-lane-runs-v6.jsonl`, `system_log_2026-09-17.jsonl`·`-18.jsonl`, `config/keepers/*.memory-journal.jsonl` 이다. 집계 스크립트는 작업 세션의 임시 파일이라 저장소에 없다. §9 의 하네스가 재현 가능한 형태로 다시 잰다.

| 관측 | 값 |
|---|---|
| Librarian 회차 | 시작 773 · 성공 659 · 실패 114 |
| 성공 회차가 받은 메시지 수 | 0개 24% (158) · 1~71개 35% (229) · 72개 상한 41% (272) |
| 성공 회차 사이 최대 간격 | won-chik 68턴 · lane-smith 65턴 · rondo 64턴 |
| 성공 회차 걸린 시간 | p50 21초 · p90 583초 · 최대 15,649초 |
| 서버 재시작에 끊긴 회차 | 70건 (`server_restarted`) |
| 밀린 유닛을 덮어쓴 횟수 | 5,211회 (`memory lane coalesced latest snapshot`) |
| 09-18 06:15Z 재시작 이후 | 성공 0 · 실패 44 (`wire_admission_rejected:missing_deadline`, #37004). 그동안 남은 흔적은 WARN 로그뿐이다 |

claude_code·antigravity 턴 뒤의 회차는 메시지를 중앙값 1개 받았다(조인된 108건).

## 3. 사실과 다른 문장 (정정 요청)

| 어디 | 적힌 말 | 실제 |
|---|---|---|
| Memory OS RFC §3 | "librarian 이 올바르게 동작하는 한 overflow 상황은 존재하지 않는다" | 그렇게 만드는 장치가 코드에 없다. 창을 고르는 파일(`keeper_carried_front`·`keeper_carried_range`·`keeper_model_input_ledger`·`keeper_turn_driver_try_provider`·`keeper_unified_turn`)에 Librarian 참조가 0건이다 |
| Memory OS RFC §3.5 | 저널 줄에 `watermark` 를 남긴다 | 라이브 저널 키는 `change, dropped, outcome, recorded_at, revision, source` 뿐이다. 구현된 적이 없다 |
| Memory OS RFC §3.2 | 절단과 Librarian 은 독립이므로 동기화 장치가 필요 없다 | 지금은 거짓이다(맨 뒤 72개만 읽으므로 그 밖은 영영 안 읽힌다). 이 RFC 가 넣는 "위치부터 이어 읽기"가 있으면 참이 된다 |
| 창 RFC §13.6 | "그 앞은 이미 기억에 있으므로" | 지금은 거짓이다(D1·D4·D6). 이 RFC 가 이행된 뒤에 참이 된다 |
| 창 RFC §13.6 | "고를 것이 없고 틀릴 수도 없다" | 위치가 안 읽은 구간을 넘어가면 틀린다. 읽은 데까지만 옮길 때 참이다(§4.2 I1) |
| 창 RFC §13.6 | 도구 결과 마커는 "지금은 거절 경로의 `last_resort` 에서만 켜진다" | 끝난 턴의 도구 결과는 이미 조립 때 마커로 나간다(RFC-0363, 기본 켜짐). `last_resort` 가 바꾸는 것은 지금 턴의 결과다 |

Memory OS RFC 의 세 문장은 §8 의 문서 PR 에서 고친다. 창 RFC 의 세 문장은 Draft #37008 의 소유자에게 요청한다.

## 4. 설계

### 4.1 뇌는 자기 루프로 돈다

- Librarian 은 **서버가 소유한 상시 루프**다. Keeper 마다 하나다. 서버가 뜨면 같이 뜨고, 뜨자마자 한 번 돈다. 그래서 재시작 뒤에도 읽던 자리에서 이어간다.
- 몸이 하는 일은 하나뿐이다. **턴이 끝났다는 사실을 기록한다**(§4.3). Librarian 입력을 만들거나 큐에 넣지 않는다.
- 뇌는 신호에 깨어나고, 깨어나면 **저장된 상태를 직접 읽어** 할 일을 고른다. 신호는 귀띔일 뿐이라 놓쳐도 잃는 것이 없다. 깨우는 신호는 셋이다: 턴 끝이 기록됨, 기억이 커밋됨(`Keeper_memory_commit_notifications`), 받은 일이 바뀜(`Keeper_librarian_queue_signal`).
- 할 일이 남아 있는 동안 **한 번에 LLM 호출 하나씩** 계속 돈다. 없으면 신호를 기다린다. 주기도 타이머도 cadence 도 없다.
- 종료 때는 루프를 취소한다. 위치는 저장이 끝난 뒤에만 옮기므로 도중에 끊겨도 잃는 것이 없다. Keeper 재기동이 Librarian 을 기다릴 이유도 사라진다. `begin_librarian_lifecycle`·`abort_librarian`·`drain_and_join_librarian` 과 그 호출자(`keeper_supervisor.ml`, `keeper_supervisor_supervise_keepalive.ml`, `keeper_keepalive_launch_transaction.ml`, `keeper_shutdown_prepare_join.ml`)를 걷어낸다.
- 같은 모양이 저장소에 있다: 서버 소유 daemon, wake, promise 로 잠들기(`server_workspace_memory_curator.ml` `start_with`). Workspace Curator 는 기능이 완성되지 않았으므로 모양만 빌리고 루프 테스트는 새로 쓴다.

### 4.2 지켜야 할 것

각 항목은 테스트로 증명한다.

- **I1 순서·빠짐없음** — 끝난 턴은 하나도 빠짐없이 순서대로 읽힌다. 읽는 단위는 "기록된 턴 끝과 다음 턴 끝 사이"다. 일어난 일이지 고른 숫자가 아니다.
- **I2 기억 먼저, 위치는 맨 끝** — ① 의 쓰기 순서는 facts, 그다음 진행 파일(읽은 위치와 하던 일을 한 번에 원자적으로)이다. 중간에 죽으면 같은 턴을 한 번 더 읽는다. 글자가 같은 중복은 `memory_id = SHA256(claim)` 이 거르고, 말만 바뀐 중복은 ② 가 접는다. 위치만 옮겨지고 기억이 빠지는 일은 없다.
- **I3 안 읽고 넘어가면 기록한다** — 기록 없는 건너뛰기는 없다.
- **I4 밀림이 보인다** — `끝난 턴 − 읽은 턴` 이 typed 값으로 TUI 와 대시보드에 뜬다. Gate 가 아니다.
- **I5 실패는 위치를 막지 않는다** — ②·③ 이 실패해도 ① 은 돈다. ②·③ 이 도는 동안 끝난 턴은 그 호출이 끝난 뒤에 읽힌다. 호출 시간 제한만큼 늦는다. Keeper 하나에 루프 하나만 두는 대가다.
- **I6 코드에 고른 숫자 없음** — 72, cadence 3, "실패하면 3턴 뒤"를 지운다. confidence 문턱도 두지 않는다.
- **I7 몸은 뇌를 기다리지 않는다** — Keeper 기동, 재기동, 턴 진행 어디에도 Librarian 완료를 기다리는 자리가 없다.

### 4.3 파일 둘을 새로 둔다

기억 스냅숏과 턴 기록은 필드 이름이 정확히 일치해야 디코딩된다(`keeper_memory_os_current.ml` `of_json` 의 `exact_field_names_result`, `turn_record.ml` `of_json`). 스냅숏에 필드를 더하면 배포와 롤백 때 모든 Keeper 의 facts 가 격리된다. 턴 기록에 더하면 hard cut 이 배포 preflight, raw-trace 정리, 창의 첫 요청까지 번진다. 턴 기록은 24시간마다 지워지기도 한다(`server_runtime_startup_maintenance.ml`). 그래서 둘 다 기존 저장소 밖에 둔다.

1. **턴 끝 기록** `<keepers_dir>/<keeper>.turn-boundaries.jsonl`
   - 끝난 턴마다 한 줄: `turn_ref`, `end_atom`, 그 atom 을 여는 메시지 digest, 끝난 시각.
   - checkpoint 가 없는 턴(공식 클라이언트)은 typed "atom 이력 없음" 줄을 남긴다.
   - checkpoint 저장 뒤에 쓰고(`keeper_agent_run_finalize_response.ml` 의 checkpoint 저장 바로 다음), 쓴 뒤 뇌를 깨운다.
   - 어휘는 기존 `Runtime_model_input_tail_window.atom_opening_digest` 를 그대로 쓴다. 창 조립의 `project_from_atom ~first_atom` 과 같은 단위다.
   - 턴의 시작은 적지 않는다. 직전 턴의 끝이 곧 시작이다. `demote_before` 는 resume·HITL 턴에서 안전한 하한이 아니다(그 턴들은 user 메시지가 이미 checkpoint 에 들어간 채로 시작한다).
2. **진행 파일** `<keepers_dir>/<keeper>.librarian-progress.json`
   - 세션(trace) id, 마지막으로 읽은 턴 끝(atom 번호, digest, `turn_ref`), 그 시점의 하던 일(`context`, `next_steps`), ② 가 마지막으로 접어 본 facts revision.
   - 쓰는 곳은 그 Keeper 의 Librarian 루프 하나다.
   - 없으면 "아직 읽은 적 없음"이다. 추측이 아니라 사실이다.
   - 못 읽거나 이력과 맞지 않으면 typed 오류다. 빈 상태로 떨어뜨리지 않는다. 빈 상태가 되면 이력 전체가 밀린 것으로 보인다.
   - checkpoint 버전이 바뀌어 이력이 새로 시작하는 자리(`keeper_context_core.ml` 의 `Superseded_version` 처리)와 purge 도구가 이 파일을 같이 다시 맞춘다.

두 파일 모두 Keeper purge 변형(`keeper_shutdown_types.ml`, `server_dashboard_http_delete_actions.ml`)과 배포 preflight 의 저장소 목록(`bin/deployment_preflight_helper.ml`)에 등록한다.

### 4.4 뇌가 하는 세 가지 일

루프는 돌 때마다 저장된 상태를 보고 ① > ③ > ② 순으로 하나를 고른다.

| | ① 턴 읽기 | ② 기억 접기 | ③ 받은 일 정리 |
|---|---|---|---|
| 고르는 조건 | 안 읽은 턴이 있다 | 읽을 턴이 없고, facts revision 이 마지막으로 접어 본 값과 다르다 | 받은 일이 마지막 정리 뒤에 바뀌었다 |
| 입력 | durable checkpoint 의 `[읽은 끝, 다음 턴 끝)`, Keeper 역할, 지금 "하던 일" | facts, Keeper 역할 | 미처리 sources, 이전 pockets (지금과 같다) |
| 싣지 않는 것 | facts 전체 | 대화 | 대화, facts |
| 출력 | `new_claims`(`supersedes`·`absorbs` 없음), 하던 일 | `absorbs` 달린 `new_claims`, `dropped`(교정과 모순 정리 포함) | `working_contexts` |
| 저장 | claim 이 있을 때만 `apply_disposition`, 그다음 진행 파일 | `apply_disposition`, 그다음 진행 파일의 접은 revision | `Keeper_librarian_context.commit` (지금 그대로) |
| 실패하면 | 위치가 안 움직인다. 다음에 같은 턴부터 읽는다 | facts 가 덜 접힐 뿐이다 | 지금과 같다 (WARN) |

- ① 은 claim 이 없으면 스냅숏을 건드리지 않는다. `apply_disposition` 은 바뀐 것이 없어도 스냅숏(150~330KB)을 다시 쓰고 커밋 알림을 낸다.
- ① 은 LLM 을 부르기 전에 진행 파일을 쓸 수 있는지 먼저 본다. 위치 쓰기가 계속 실패하면 같은 턴을 끝없이 다시 읽어 facts 만 불어난다.
- ① 이 facts 를 안 보므로 같은 지식을 되풀이해 넣을 수 있다. 그 양은 §9 의 하네스로 잰다. 크면 ① 에 facts 를 싣는 안을 다시 판정한다. 재기 전에 정하지 않는다.
- 밀린 턴을 읽을 때는 그 턴의 것이 아닌 입력을 싣지 않는다. 상대방 관측은 턴 끝 시각 사이로 끊는다. Goal 기준은 가장 최근 턴에만 싣는다. 도구 성공·실패는 메시지의 `is_error` 표시로 충분하다.
- 일마다 프롬프트 키, 스키마, 디코더를 따로 둔다. 키는 새로 만든다. 라이브 설정의 옛 `librarian` 덮어쓰기가 새 계약에 묶이지 않게 하기 위해서다. `execute_exact_output_classified` 는 `~requirement ~validate` 를 받게 넓힌다. 레인은 `librarian_exact` 하나를 같이 쓴다. 스냅숏의 `source.kind` 는 나누지 않는다(엄격 디코드). 일의 종류는 `Exact_lane_run_registry` 행에만 남긴다.
- checkpoint 를 디스크에서 읽는 비용은 하네스와 라이브에서 잰다. 크면 깨우는 신호에 메모리 속 메시지를 귀띔으로 같이 넘기되, 턴 끝 digest 가 맞을 때만 쓴다.

### 4.5 하던 일

- ① 이 턴을 읽고 나서 고쳐 적는 글이다. 지금 무슨 일을 하고 있는지, 어디까지 했는지, 다음에 할 일이 무엇인지를 담는다. 현재 상태만 적으므로 쌓이지 않는다.
- 읽은 위치와 같은 파일에 같이 적는다. 그래서 이 글이 다루는 범위는 늘 "위치까지"다. 위치 뒤의 일은 창에 실린 원문이 말한다. 둘은 겹치지도 비지도 않는다.
- Keeper 턴의 첫 요청에 본문으로 싣는다. 기존 `Memory_os_recall` 블록과 같은 자리다(`keeper_run_tools_hooks.ml`).
- pocket 저장소(working-context)에는 담지 않는다. pocket 은 미처리 source 가 있어야만 존재하고(`keeper_librarian_context.ml` `select`·`commit`), Keeper 에게는 작은 artifact 참조만 주기로 한 설계이며(`docs/design/librarian-working-context.md`), `next_steps` 는 다음 턴이 시작하면 가려진다. 받은 일 정리(③)는 그 설계대로 둔다.
- `config/prompts/librarian.md` 의 "턴 진행과 현재 상태는 저장하지 않는다"는 facts 에 대한 규칙으로 남는다. 하던 일은 facts 가 아니다.

### 4.6 공식 클라이언트 턴

이 턴들은 checkpoint 가 없어 atom 이력이 없다. 읽을 거리는 있다. `history.jsonl` 에 user·assistant 메시지가 모든 레인에서 남는다(`keeper_context_core_history.ml` `persist_message`). ① 은 그 턴의 시각 사이에 남은 줄을 읽는다. 지금(assistant 메시지 1개)보다 더 읽는다. atom 위치는 움직이지 않는다. 이 레인의 창을 어떻게 볼지는 이 RFC 의 범위가 아니다.

### 4.7 보이는 것

- TUI Memory 헤더, health JSON, 대시보드에 `끝난 턴 − 읽은 턴`, 마지막 성공 시각, 마지막 실패 종류를 싣는다. 값은 진행 파일과 저널 꼬리에서 읽는다. 지금의 카운터는 서버 기동 이후 값이라 쓰지 못한다.
- 일의 종류(①·②·③)는 `Exact_lane_run_registry` 행에 남아 회차별 시간과 실패를 나눠 볼 수 있다.

## 5. 하지 않는 것

- **숫자 문턱, 가중치, confidence 게이트, "최근 K턴" 창.** 경계는 고른 숫자가 아니라 일어난 일이다(창 RFC §13.6).
- **컴팩션(LLM 요약으로 이력을 고쳐 쓰기).** 하던 일은 이력을 고치지 않는다. 따로 적는 글이고, 이력은 증거로 남는다.
- **엄격하게 디코딩되는 기존 저장소에 필드 더하기.** §4.3 의 이유다.
- **두 번째 실행 줄.** ② 를 따로 돌리면 lifecycle·취소·종료가 두 벌이 된다. I5 의 대가를 받아들인다.
- **판단 전용 모델을 운영 경로에 넣기.** exact-output 경로는 chat 모양이라 공급자 종류를 더하는 비용이 크고, 모든 Keeper 대화가 외부로 나간다. 틀린 "남길 것 없음"은 조용한 기억 손실이다. 하네스 채점자로 먼저 쓴다.
- **공식 클라이언트 레인의 창.** 별도 RFC 다.

## 6. 이 RFC 가 닫지 않는 것

- 도구 결과 본문. ① 은 지금처럼 읽지 않는다. 끝난 턴의 도구 결과는 blob 마커로 다시 열 수 있다(RFC-0363).
- facts 와 고정 브리핑이 혼자 모델 한도를 넘는 경우(창 RFC §13.9).
- 슬롯 넘김(#36979)과 exact 레인 deadline 선언(#37004). ① 이 창을 좌우하기 전에 둘 다 닫혀 있어야 한다.
- Workspace Curator 마무리.

## 7. 나중 단계

(가)가 라이브에서 확인된 뒤 하나씩 연다.

- **(나) 턴 도중에도 읽는다.** 도구 경계 checkpoint 가 저장될 때도 뇌를 깨운다. 그때까지를 읽어 하던 일만 새로 고친다. 창이 보는 위치는 턴 끝에서만 옮긴다. 턴 도중에 옮기면 Keeper 가 방금 받은 결과를 잃고 접두사 캐시가 깨진다. 진행 파일에 "뇌가 읽은 곳"과 "창이 보는 곳" 두 위치가 생긴다.
- **(다) 한가할 때도 정리한다.** 읽을 것도 접을 것도 없으면 아직 다시 보지 않은 기억 묶음을 하나씩 본다. 묶음마다 "이 revision 에서 봤다"를 남긴다. 새 정보 없이 같은 기억을 되풀이 판정하지 않기 위해서다. 통째 재작성은 내용이 무너진다(RFC-0456 §4.4, 창 RFC §6.4 의 ACE). 다 봤으면 쉰다.

## 8. 이행

스택 PR 로 나눈다. 각 PR 은 20k 토큰 이하다.

| 단계 | 내용 | 혼자 들어가도 안전한 이유 |
|---|---|---|
| 1 | 턴 끝 기록. 쓰기만 하고 읽는 곳은 없다. purge·preflight 등록 | 동작이 바뀌지 않는다 |
| 2 | 하네스(§9) | 저장소 밖 실행 |
| 3a | `execute_exact_output_classified` 일반화, 진행 파일 저장소 | 동작이 바뀌지 않는다 |
| 3b | 서버 소유 루프. 이 단계에서는 ① 만 한다. 새 프롬프트·스키마·디코더, 저장 순서 I2 | 옛 회차가 Keeper 경로에서 제 주기로 계속 돌며 접기와 받은 일 정리를 맡는다. 잠깐 둘이 같이 돈다 |
| 4 | ② 를 루프로. cadence·72 와 그 소비자를 같은 PR 에서 지운다(설정, 런타임 설정 등록, health JSON, TUI·대시보드 디코더, 저널의 `cadence_deferred`, 그 값을 핀한 테스트) | ① 이 이미 읽기를 맡고 있다 |
| 5 | ③ 을 루프로. Keeper 경로의 Librarian 제출과 lifecycle 결합을 지운다. Librarian 스키마·프롬프트 키 하나를 가정하는 곳(`bin/masc_lane_cli_probe.ml`, 대시보드 prompt-registry 패널)을 같이 고친다 | 세 일이 모두 루프에 있다 |
| 6 | 하던 일 주입, 밀림 표시 | |
| 7 | Memory OS RFC 와 docs-site 의 사실과 다른 문장 정리 | 문서만 |

4단계는 저널 줄의 형식을 바꾼다(`cadence_deferred` 삭제). RFC-0456 §5 는 저널 형식을 바꾸지 않는다고 적었으므로 이 RFC 가 그 부분을 대신한다. 지우는 개념의 흔적은 "더 이상 쓰지 않음" 같은 표기 없이 같은 PR 에서 지운다.

## 9. 검증

**하네스 먼저.** 1단계가 쌓은 실제 턴 끝으로 라이브 checkpoint 를 잘라 ① 프롬프트 후보를 오프라인으로 돌린다.

| 재는 것 | 뜻 |
|---|---|
| 빠진 턴 | I1. 0 이어야 한다 |
| 출력 거절률 | 새 스키마를 모델이 지키는가 |
| 회차당 시간, checkpoint 읽는 시간 | ① 이 턴을 따라잡을 수 있는가. 지금은 p50 21초·p90 583초 |
| ① 이 같은 지식을 되풀이해 넣는 양 | ① 에 facts 를 실을지 판정할 근거 |
| 연속성 | 턴 t 의 내용으로 질문을 만들고, (facts + 하던 일 + 위치 뒤 원문)만 본 답이 그 내용을 담는지 본다. 채점은 Jev Noul 로 한다. 문턱으로 가르지 않고 분포를 기록한다 |

연속성 채점은 대화를 외부 업체로 보낸다. 대상 Keeper 는 실행 전에 운영자가 고른다.

**라이브.**

- 1단계 뒤: `turn-boundaries.jsonl` 에서 턴 N 의 끝 다음에 턴 N+1 이 이어지는지 본다. 일반, resume, HITL, 재시도, failover, 재시작 턴을 모두 본다. digest 가 재시작을 넘는지 본다.
- 3b 뒤: 진행 파일이 턴마다 움직이는지, 서버를 재시작해도 읽던 자리에서 이어가는지, Keeper 재기동이 Librarian 을 기다리지 않는지 본다.
- 6단계 뒤: Librarian 슬롯을 비워 멈춘 뒤 밀림이 한 턴 안에 화면에 뜨는지 TUI 와 브라우저 스크린샷으로 남긴다.

위가 확인된 뒤에야 창 RFC §13 의 삭제(마크, 바이트 컷, `halve`, `Whole_history`)가 시작될 수 있다.

## 10. 열어 둔 결정

1. **기존 Keeper 전환.** 이력이 수천 atom 쌓여 있고 위치가 없다. 이력을 비우고 시작할지, 위치를 지금 끝에 찍고 "0부터 여기까지는 안 읽음"을 기록으로 남길지. 기록 없이 끝에 찍는 것은 하지 않는다.
2. **턴 하나가 어떤 슬롯에도 들어가지 않을 때.** 건너뛰고 기록하면 constitution `failure_keeps_evidence`("대상을 소비하지 않는다")와 부딪힌다. 멈추면 위치가 영영 안 움직이고, 창 RFC §13 아래에서는 "Keeper 가 턴을 못 돈다"로 이어진다. 둘 중 무엇을 받아들일지.
3. **① 에 facts 를 실을지.** 하네스의 되풀이 양을 보고 정한다.
