# C-collab 감사 (origin/main b99c9d77b5, 2026-10-07)

> 작성 순서 메모: 섹션을 끝나는 대로 덧붙였다. 번호가 섹션 순서다.

## 2. 7일 흐름 (협업·통제 경로 커밋만, 병합/rebase 포함)

경로: board*, task*, goal*, schedule*, auth, workspace, keeper_approval, gate, lane_addon, lane_registry, fusion. 건수 W1..W7 = 15/15/33/12/13/0/25.

- D-7→D-6 (09-29~30, 15건): Goal 공유·행위자 기록(#39975), Goal 기한·priority 수정 이벤트화(#39951), 일정(schedule) 성능 3건(#40022 #40026 #40034), 일정 withdraw(#40006), Board 스냅숏 부분 직렬화(#39989), auth 설정 stat 스레드(#39935). 성능·정합 보강이 중심.
- D-6→D-5 (15건): Board 목록 캐시 비우기(#40451), 스냅숏 변화 없으면 flush 건너뜀(#40488), Task GC archive 순서(#40427), Lane 영수증 내구성(#40396 #40573), cron 단일 step 거절(#40460). 같은 주제(Board 스냅숏)가 D-7 #39989 → D-6 #40488 → D-1 #41459 로 세 번 손댐 (아래 결함/지울 것 참고).
- D-5→D-4 (33건): 대부분 `Rebase PR #… with preserved resolved source`, `merge:` 커밋. 실질 변경은 Fusion 증거를 Lane 출력에 연결(#40184 #40189), auth 별칭(alias) sidecar 정리(772d488c81), Board 빈 hearth 처리(0e84eef7bb), Lane 영수증 동기화(#40582). 병합·rebase 커밋이 실제 기능 커밋보다 많다 (스택 PR 운영 비용).
- D-4→D-3 (12건): 거의 전부 `rebase(stack): carry current parent repair into PR #…`. 기능 변화 없음 (#40975 중복 테스트 바인딩 제거 하나만 실질).
- D-3→D-2 (13건): Goal 증명(proof) 재시도·감사 복구 5건(#41003 #41053 #41134 #41136 #40997), verifier 승인 내구 전달(#41004), cron wildcard step(#41021)과 D-6의 #40460이 같은 영역 두 번째 fix, Lane sampling 복구 3건.
- D-2→D-1 (10-04~05): 이 경로에 커밋 0건.
- D-1→HEAD (25건): Goal Pause/Resume·Block/Unblock 복원(#41151), drop 사유 필수(#41357), drop 시 미할당 Task 취소(#41342), 증명 요청이 상태기계에서 다음 상태를 받게 함(#41455), Board flusher CAS 재시도 상한 제거(#41459), Lane 패키지 on/off와 공통 inventory(#41130 #41135 #41162 #41185), 크기 검사 제거 리팩터 6건(#41269 #41281 #41287 #41279 #41288 #41290).

되돌림·덧칠 징후:
- 일정 cron: #40460(D-6) → #41021(D-3). 같은 step 해석을 두 번 고침. 2번째 fix 규칙 대상.
- Goal 증명 전달: #40997 #41003 #41004 #41053 #41134 #41136 (D-3 하루 6건) 후 #41455(D-1)에서 상태기계로 흡수. 앞선 call-site 패치를 구조 변경이 뒤늦게 대체한 패턴.
- Lane 크기 검사: D-1 하루에 "drop two redundant size checks"가 #41269 #41281 #41287 #41279 #41290 #41259 로 6건. 이전에 넣은 상한(reply bound)을 걷어내는 중 (아래 §4 참고, 근거 확인함).
- Board 스냅숏: #39989 → #40488 → #41459 (아래).

## 부록 A. 조사 노트 (기능별, 증거 원본)

코드 기준 origin/main b99c9d77b5. 경로는 `lib/` 아래. 확신도 H/M/L.

### A1. Goal
- Goal 모델은 단일 JSON(`goals.json`)에 goals + pending_events + pending_notifications를 같이 둔다 (goal/goal_store.ml:672-715 `transact_goal`). 파일 락 하나로 직렬화. 현재 live goals.json 413줄, goal_events.jsonl 80행 86KB (작음). 닫힌 구조: outbox(pending_events)는 `flush_pending_events_locked`(goal_store.ml:898)가 비우고, 알림은 recipient 전원 ack 후 지워짐(`acknowledge_notification`, goal_store.ml:1176). (H)
- 상태기계는 exhaustive (goal/goal_phase.ml `decide_transition`, catch-all 없음). 좋음. 단 문자열 표가 3벌: `Kind.to_string/parse`, `of_string/parse`(goal_phase.ml:13-35), `Public_action.of_string`+`action_of_string`(:88-103). 같은 문자열 대응이 Kind(7종)와 phase(5종만)로 따로 있고, `of_string`은 paused/blocked를 일부러 못 읽는다. (H, P3)
- "Goal tree" / "proposal"은 코드에 없다. goal 타입에 parent/children 필드가 없고(goal_store.mli:33-46), `rg 'goal_tree|parent_goal'`는 대시보드/TUI 표시용 몇 곳만 잡는다. 의뢰서의 "goal tree, proposal"은 존재하지 않는 개념 (H). 용어 정리 필요.
- drop 경로 결함 (P2, M): `finish_goal_drop`(workspace_goals.ml:867-909)은 Goal 전이 커밋 뒤에 Todo Task를 취소한다. 취소 실패는 `cancel_failed`로 응답에만 실리고, 이미 Dropped인 Goal에 drop을 다시 부르면 `changed=false`라서 `tasks=[]`(:895) — 재시도로 남은 Todo를 취소할 길이 없다. 프로세스가 중간에 죽어도 같다. Task GC가 이 고아를 치우는지는 not checked.
- `Goal_store.update_goal_if_phase`(goal_store.ml:717)는 production caller 0, test_goal_store.ml에서만 호출 (rg 확인). 지울 후보 (H).
- handle_goal_transition(workspace_goals.ml:976-1086)은 `Already`/`Move_to` 두 갈래에 Reopen/Pause/Resume/Block/Unblock/Drop 처리를 똑같이 두 번 적었다. 한 번에 합칠 수 있다 (S).
- 확정 권한: `/api/v1/goals/confirmation`은 `with_token_permission_auth ~permission:CanAdmin`(server_routes_http_routes_verification.ml:~170-195)로 operator 토큰만 통과, 증거(criterion_revision, request_id, verification_run_id) 4개를 모두 맞춰야 한다 (workspace_goals.ml:1093-1112). 견고함 (H).
- `masc_goal_transition` HTTP 경로(server_routes_http_routes_activity.ml:1390-1425)는 `with_tool_actor_auth`만 쓰고 workspace 사전조건(`expected_workspace`)을 보지 않는다. #41501(OPEN)이 이걸 메우려는 것. 아래 A6 참고.

### A2. HITL (Gate = 승인 큐 + Auto Judge)
- 큐 단계는 4개 variant (`Phase_queued|judging|human_required|blocked`, keeper_contract/keeper_approval_queue_rules_types.ml:100-127), `phase_of_disposition_and_summary`(:150-179)가 disposition × summary 상태로 계산하는 파생값. 파생이라 저장 불일치가 없다 (H). 단 `Summary_attempt_settled`+Approve/Deny → `Phase_judging`, `Ready`+같은 조합 → `Phase_queued`로 갈린다(:164-178). 의미 설명 주석이 없어 읽는 사람이 헷갈린다 (P3, L).
- Auto Judge가 `Approve`를 내면 사람 확인 없이 `resolve_with_policy ~source:Auto_judge`로 도구 호출이 풀린다 (keeper/keeper_gate.ml:565-590 `resolve_judgment`). `Require_human`만 `Judgment_skipped`. 설계상 자동 승인이 켜진 구조이므로 이 권한이 "advisory"라는 타입 이름(`advisory_judgment`)과 맞지 않는다 — 이름은 자문, 동작은 결정. (H, 용어 P3)
- Require_human 행은 `Summary_attempt_settled`+`Summary_available`로 계속 pending (keeper_gate.ml:779 주석: 2026-07-28 18건이 2416초 막힌 사고 뒤 선택 로직을 "head만 보지 않게" 바꿈). 닫힌 구조 아님: 사람이 풀지 않으면 큐는 무한히 쌓인다. 만료/상한 코드는 not checked.
- `active_auto_judges`는 프로세스 메모리 Atomic Map (keeper_gate.ml:632-700). 재시작하면 비고, 디스크의 start_reserved가 "내 프로세스에 claim이 없으면 고아"로 취급되는 방식으로 복구(:688-700 주석). 설계 일관 (M).
- 이름 충돌: "Gate"가 (a) 승인 큐 keeper_gate.ml, (b) 채널 연결 `lib/gate/` (Slack/Discord/iMessage), (c) Goal 증명 `gate_verdict` (workspace_goals.ml:413) 3가지 뜻. 아래 §6.
- 파일 크기: keeper_approval_queue.ml 3182줄, keeper_gate.ml 2386줄, rules_types 977줄. 300줄 기준의 10배. 분할 대상 (S 규칙 위반, 사실).

### A3. Access control
- 역할 3종 Worker/Admin/Player, 권한 10종 (types/types_auth.ml:302-315,334-368). `has_permission`은 exhaustive match. `permissions_for_role` 리스트와 `has_permission` match가 같은 표를 두 번 적었다 (주석이 "parallel"이라 인정, types_auth.ml:350-365). SSOT 위반, 어긋나도 컴파일러가 못 잡는다 (리스트 쪽은 exhaustive 검사 없음). P3.
- `MASC_AUTH_STRICT` (auth/auth_strict_mode.ml) 은 Off/Dry_run/Strict 3값인데 쓰는 곳은 mcp_server_eio_caller_identity.ml:167-185 하나뿐이고, Dry_run과 Strict 분기 동작이 같다 ("Phase B PR-2가 reject한다"는 로그만 찍음). 파일 마지막 변경이 무관한 커밋. 기본값 Dry_run, 모르는 값도 Dry_run. 토큰이 풀리지 않으면 호출자가 준 이름을 그대로 쓴다 (":keeping caller alias"). 하루 936건(2026-04-26 측정, 파일 주석)이라는 근거로 만든 "측정 단계"가 6개월째 안 닫혔다. telemetry-as-fix 서명 1번에 해당 (H, P2).
- 또 하나의 `strict`: `http_auth_strict_enabled()`(server/server_auth.ml:23-26)는 loopback이 아닌 바인드이거나 env로 켠다. 이름 같은 별개 개념. 용어 충돌 (§6).
- `is_public_read_path`(server_auth.ml:1003~)는 길이가 긴 `||` 나열(문자열 prefix 분류). 비-strict(loopback 기본)에서는 `with_public_read`가 인증 없이 통과 (server_auth.ml:1213-1223). loopback 전제. (M)
- operator vs keeper vs agent: `schedule_caller`(server_routes_http_routes_activity.ml:112-126)가 credential 종류 4가지(Operator/Agent/Player/No_credential)를 typed로 나눈다. 좋은 설계 (H). 같은 구분이 board 쓰기에는 `board_actor_author_for_write`로 따로 있다 — 두 번째 쓰임이라 추상화는 정당.
- `module For_testing`이 server_auth.ml 끝(:1310-)에 있어 서버 상태/auth config를 갈아끼운다. 리포 전체 `module For_testing` 218개 파일 (rg -c). 체크리스트 6번(test backdoor) 대량 선례. 개별로는 P3, 합쳐서는 패턴 누적 (§7).

### A6. Workspace binding of writes (#41501 확인)
- 서버 검사 함수는 하나 (workspace/workspace_utils_paths_backend.ml:29-48 `validate_expected_workspace`)지만 **필드가 없으면 `Ok args`** (:34 `[] -> Ok args`). 필수가 아니다.
- HTTP 쓰기 라우트별 현황 (server_routes_http_routes_activity.ml): board_vote(:1264)·board_post(:1295)·board_comment(:1337)는 선택 검사. **board_comment_vote(:1355-1385)는 검사 없음**, goal_transition(:1390-1425) 검사 없음, schedule_create/update/cancel(:1427-1490) 검사 없음. 한 파일 안에서도 4가지(선택 검사 / 없음 / 필수는 #41501만 / 다른 파일 dashboard·keeper_stream은 각자 호출)로 갈린다. N-of-M 서명 3번, 체크리스트 3번. 근본 해결은 `with_tool_actor_auth` 래퍼가 `expected_workspace`를 받아 공통 처리하는 것 (P2, H).
- 이 파일의 POST 라우트 본문이 25줄씩 복사됨 (JSON 파싱→검증→Tool 호출→응답, :1248-1490 8개). `Server_routes_http_common`에 이미 같은 모양이 있는지는 not checked.

### A4. Task
- 상태 6종 (`Todo|Claimed|InProgress|AwaitingVerification|Done|Cancelled`, types/types_core.ml:213-231), 전이는 `Workspace_task_lifecycle.decide`에서 결정, 이유는 typed error (`Verification_submission_required|Verification_pending_verdict|Cancel_reason_required|Invalid_transition`) (workspace/workspace_task_transitions.ml:~190-245). 정상 경로 탄탄. 검증 요청은 훅이 안 꽂혀 있으면 fail-closed 에러 (workspace/workspace_hooks.ml:296-321). 좋음 (H).
- 같은 파일 `(match action, task.task_status with ... ) [@warning "-4"]` (transitions.ml:~165): 경고 4(fragile match)를 끄고 `| _ -> Ok ()`로 받는다. 새 action 추가 시 컴파일러가 못 잡는 자리. 단 바로 위 arm이 action 전체를 열거하고 있어 실제 위험은 낮다 (P3, M).
- **Task GC는 수동뿐** (open loop): `Workspace.gc`의 호출처는 tool_misc.ml:79 `masc_gc` 도구 하나 (rg 전수). 주기 실행 없음. live: backlog.json 1209건 4.2MB, 그중 done 462 + cancelled 668 = 93%가 종결 상태 (2026-08-26~10-07). `tasks-archive.json` 마지막 쓰기 09-20. 그리고 backlog는 전이마다 통째로 다시 쓴다 (+`.last-good` 미러): 4.2MB x2. version 13962. 닫힘 아님 — 연 기간에 비례해 커진다 (H, P2).
- Goal drop 연동 (#41342)은 Todo만 취소, 잡힌 Task는 알림만 (A1 참고).
- **Hebbian 훅은 쓰기 전용 죽은 개념** (P2, H): Task Done이면 `hebbian.strengthen`, Cancel이면 `hebbian.weaken` 활동 이벤트를 (작업 중인 에이전트 수만큼) 낸다 (workspace/workspace_core.ml:174-216, workspace_task_cleanup.ml). 읽는 곳이 없다: `rg hebbian`은 emit 지점·훅 정의·테스트 한 곳뿐. live 활동 로그 2026-10-06: 40,075행 중 hebbian 8,720행(21.8%, weaken 8,113 / strengthen 607). 하루 약 3.5MB. 이름은 "learning"인데 학습은 없다.
- `Workspace_hooks`는 Atomic 함수 슬롯 36개 (workspace_hooks.ml 400줄). 기본값이 permissive인 슬롯이 있다: `schedule_wake_target_registered_fn` 기본 `Ok true` (workspace_hooks.ml:~66-70, "embedded contexts keep creating schedules"). 배선이 빠지면 존재하지 않는 Keeper 앞 일정도 통과 (Unknown→Permissive, P3, M — 서버는 부팅 시 설치한다고 주석에 있음, 미설치 감시 테스트는 not checked).

### A5. Schedule
- 모듈: schedule_domain(970줄, 자체 cron 파서·다음 시각 계산) → schedule_store → schedule_runner(tick) → server_schedule_consumers(Keeper wake 소비) → server_bootstrap_maintenance(루프). 
- cron: 5필드 파서 직접 구현 (schedule_domain.ml:365-545). dom/dow 규칙은 Vixie 방식(둘 중 하나가 `*`로 시작하면 AND, 둘 다 제한이면 OR, :706-718)을 따른다. 달력 일 단위로 전진해 임의 지평선이 없다 (:726-760). 이번 주 fix 2건(#40460 단일값 step 거절, #41021 와일드카드 step 일 매칭)은 코드상 반영됨. 현재 로직에서 결함은 못 찾음 (M). 같은 영역 2번째 fix였으므로, 자체 파서 대신 속성 테스트(모든 분 단위 열거와 대조)가 있는지가 관건 — test 존재 not checked.
- 타임존: UTC/Asia/Seoul/KST/고정 오프셋만, IANA·DST 미지원을 오류 메시지로 명시 (:350-362). 정직함 (H).
- N-Tick: Interval 일정만 self-clock(이전 occurrence가 안 소비되면 보류, 최대 1개 pending) (server/server_schedule_consumers.ml:1265-1294). Cron/Daily/One_shot은 각 발화가 이전 pending을 supersede하므로 큐가 쌓이지 않는다 (같은 주석). 닫힘 (H). 보류 로그는 "시작 시 1번"만 (server_bootstrap_maintenance.ml:~60-75). 신호 로그는 `signals/` 28MB, retention_days 인자 있음 (닫힘).
- 취소: `schedule_caller` (4종 credential)가 operator vs 이름 있는 호출자를 구분 (server_routes_http_routes_activity.ml:112-126). Keeper가 operator 일정을 못 지움. 좋음 (H).
- 일정 쓰기 3 라우트는 expected_workspace 사전조건을 안 본다 (A6).

### A7. Board
- 모듈: board_types(780줄, Post_id/Comment_id/Agent_id 불투명 타입, audience variant), board_core/persist/votes/dispatch(+`lib/board.ml`·`lib/board_core.ml`... 루트 shim 11개와 `lib/board/` 안 같은 이름 17개가 공존: 루트는 `include Masc_board_handlers.X` 한 줄짜리 전달 파일 (lib/board_core.ml 등 1줄). 의도는 `include_subdirs`에서 접근 경로 유지라 주석에 적혀 있으나, 같은 이름 14개 파일이 두 곳에 있는 건 읽는 사람에게 혼란. P3.
- ID는 parse-don't-validate로 잘 짜였다 (board_types.ml:60-120). Comment_id는 mint하는 모양만 받아 환각된 id를 입구에서 막는다(134건 중 109건이 가짜 id였다는 근거 주석).
- 저장: jsonl 5종 live `board_comments.jsonl` 22MB + `.1/.2`(각 11MB, 09-14), `board_posts.jsonl` 9MB + `.1/.2`(10MB, 09-19). 회전된 백업 4개 = 42MB 정체(마지막 쓰기 3주 전). 비어 있는 loop 아님 (회전 파일은 더 안 커짐), 지울 후보 (L, 지우면 복구 불가 — 운영자 확인).
- flusher: `maybe_sweep`이 쓰기 시점마다 sweep/flush 메시지를 flusher 인박스에 예약, 가득 차면 통째로 버리고 rollback + warn + 카운터 (board_core_persist.ml:341-365). 시그니처 1·5번 (cap + telemetry) 해당하나 롤백으로 다음 호출이 재시도하므로 실제 손실은 없다. 같은 영역이 이번 주 3번 수정됨 (#39989 → #40488 → #41459 = 마지막은 "근거 없는 CAS 재시도 상한을 걷고 되돌림을 고침"), 근본 정리 중이라 판단 (M).
- 테스트 뒷문: `reset_sweep_schedule_for_test`, `sweep_schedule_timestamps_for_test` (board_core_persist.ml:390-399) 프로덕션 모듈에 노출. 체크리스트 6번. P3.
- **Board attention 후보 원장이 닫히지 않는다** (P1, H): `.masc/board_attention_candidates/<keeper>.jsonl` 57개 합 643MB, 187,062행 (board 원본은 게시물 3,024 + 댓글 14,629 = 17.6k건). 한 건이 키퍼마다 복사(약 10배)되고 행마다 게시물 전문(평균 약 3.8KB)이 실린다. 상태별: consumed 114,952행/304MB, judged 34,635/99MB, pending 33,262/81MB. 3일 넘은 pending 19,258 + judged 20,694가 정리되지 않고 남음. judged의 대부분이 `not_relevant`(30,803행)인데 이건 키퍼에게 전달할 것이 없다. 코드: `compaction_ratio=2`는 "live 후보"(전부 최신 행) 기준이라 consumed도 live로 센다 (keeper/keeper_board_attention_candidate.ml:1756-1766), 시간 기준 만료·삭제 경로는 파일에 없다 (rg 'stale|expire|ttl|retention' 0건). 서버 메모리에도 전체를 `state.latest`로 들고 있다 (candidate.ml `refresh_ledger`, :1740-1745) → 메모리 노트의 "heap 5~8GB" 요인 후보. 제안: 종결(consumed·not_relevant judged) 행은 내용 대신 candidate_id+판정만 남기거나 N일 뒤 삭제, Verdict `not_relevant`는 judged에서 곧바로 consumed로.
- 큰 파일: keeper_board_attention_candidate.ml 2450줄, worker 2438, partition 2123줄 (300줄 기준 7~8배).

### A8. Lane (routing/authority) · Fusion · Tool 권한 등급 (조사 노트)
- Lane add-on HTTP 경로(server/server_routes_http_routes_lane_addons.ml)는 호출자 신분을 `source_access`로 3종 typed (Operator_configuration / Keeper caller / Unauthenticated)로 나눠 도메인에 넘긴다 (:51-56). Player·무자격은 Unauthenticated. 좋은 구조 (H).
- 패키지 경로 입력은 둘 다 작업공간 안으로 가둔다: preview는 `Exec_policy_paths.is_within_dir` (:117-126), catalog는 `Lane_addon_catalog.within` + realpath (lane_addon_catalog.ml:14-26). 같은 검사가 두 구현 (P3, SSOT).
- GET `package-preview`가 읽기 권한(`with_read_auth`)만으로 `Lane_addon_worker.inspect_image`를 부른다 (:127-135, :155-157). 읽기 토큰으로 컨테이너 이미지 조회를 일으킬 수 있다. 부작용 있는 GET (P3, M).
- Exact lane run 저장: `exact-lane-runs-v6.jsonl`(3.1MB, 10,508행) + `exact-lane-run-payloads/` 4,243 디렉터리 1.8GB. 보존은 lane마다 최신 2,000건 (exact_lane_run_registry.ml:271-277)이라 닫힘. 하지만 **workspace_curator_exact 한 건당 입력 9MB**(실측 중앙값 9,283,652B, 222건 = 1.34GB): `actual_input.sources` 3,407개 사실(6.5MB) + 렌더된 `prompt.rendered` 3.37MB가 같은 내용을 두 번 담는다. 이 lane은 221건 중 성공 64, 실패 153(69%), 취소 4. 실패 예: glm-5.3-flash 429 `rate_limited`, 출력 372B. 상한 2,000이면 이 lane만 18GB까지 간다. 같은 glm-coding.glm-5.3-flash 한 슬롯을 hitl_auto_judge·board_attention_exact·curator 세 lane이 같이 쓴다 (config/runtime.toml:89-100).
- 죽은 데이터: `.masc/exact-lane-runs-v5.jsonl` 743MB (마지막 쓰기 09-15, 코드는 v6만 읽음: exact_lane_run_registry.ml:423), `.masc/lane-addons-archive/` 514MB (09-25, 코드 참조 0).
- Fusion: 이번 주 변경은 Lane 출력 연결(#40184·#40189)과 빈 결론 거절(#41056). live `fusion-runs.jsonl` 13KB, 마지막 10-02 (거의 안 쓰임). 깊이 검토는 not checked.
- Tool 권한 등급: `Tool_catalog.metadata`는 카탈로그에 없는 도구에 `CanAdmin`을 준다 (fail-closed, tool/tool_catalog.ml:653-668). 좋음 (H). 그러나 같은 파일의 `implementation_status`(Real|Adapter|Simulation|Placeholder)는 production에서 `Real` 말고는 만든 곳이 없다 (rg 전수: 기본값 Real, tests에서만 Simulation/Placeholder). 죽은 개념, 연결된 환경변수 `MASC_PLACEHOLDER_TOOLS_ENABLED`(:690-694, 주석에 "배포에서 쓴 곳 없다"고 적고 되살림)와 프롬프트 상수 `tool_help_constraint_{placeholder,simulation}`까지 딸려 있다 (tool_surface/tool_help_registry.ml:139-140).
- HITL live 상태: `.masc/gate/mode.json` = `always_allow` (updated_by masc-tui, 2026-09-23T03:41Z), `external-mode.json` = `always_allow` (09-15), `keeper-modes.json` = `[]`. 즉 live의 도구 승인 게이트는 전부 허용 모드이고 Auto Judge lane은 09-23 10:59 하루에 16번(성공 2·실패 14) 돈 뒤 기록이 없다. 이번 주 HITL 변경(#41464 등)이 live에서 한 번도 실행되지 않았다는 뜻이므로, 그 경로는 테스트로만 검증된 상태 (H).
- `keeper_always_allow` 플래그(Keeper 설정)는 Keeper별 모드 덮어쓰기보다 먼저 검사된다 (keeper_gate.ml:2208-2213 → 그 아래에서 `read_mode`). 주석(:2216-2219)은 "특정 Keeper를 더 엄격히 하려는 운영자 의도가 그 Keeper의 모든 일에 적용"이라 하는데, 플래그가 켜진 Keeper(live는 sangsu.toml 하나)는 Manual로 눌러도 통과한다. 의도와 순서 불일치 (P3, M).
- Ask 저장소(keeper/keeper_ask_store.ml:132-166): answer/withdraw가 "읽고 → 확인 → append"를 락 없이 한다. 두 사람이 같은 질문에 동시에 답하면 둘 다 Ok를 받고 이벤트가 2개 쌓인다 (`fold_events`는 나중 것이 이긴다, keeper_ask.ml:257-271). 확률 낮음, 증상은 조용한 덮어쓰기. P3, M. 크기 1.7MB로 작음.

> 정정 (A7, A8): (1) Board 루트 shim은 `lib/board_*.ml` 8개가 `include`만 하는 1줄 파일이고 `lib/board/`의 같은 이름과 9쌍이다(board.ml 포함). 위 "11개/14개"는 9쌍/8개 shim이 맞다. (2) Ask의 중복 응답은 `resolve`가 `Open`일 때만 값을 넣으므로(keeper_ask.ml:247-255) 먼저 쓴 응답이 이기고 나중 응답은 무시된다. 나중 호출자는 `Ok`를 받는다. "나중 것이 이긴다"는 틀렸다.

## 1. 영역 지도

| 기능 | 정본 모듈 | 저장 | 순환 장치 | 소비자 |
|---|---|---|---|---|
| Board | lib/board/ (core·persist·votes·dispatch), board_types/ (불투명 ID, audience), board_tool_adapter/ (MCP 도구) | `.masc/board_{posts,comments,votes,reactions}.jsonl` (메모리 Hashtbl + dirty flusher actor) | `maybe_sweep` → flusher 인박스 (Sweep/Flush) | MCP 도구, `/api/v1/tools/masc_board_*`, 대시보드, Board attention |
| Board attention | keeper/keeper_board_attention_{candidate,partition,worker,...} | `.masc/board_attention_candidates/<keeper>.jsonl`, `board_attention_partitions/` | worker가 후보를 판정(Jev) → 키퍼 턴이 consume | 키퍼 wake, 운영자 quarantine 명령 |
| Task | workspace/workspace_task_*, task/tool_task_*, types/types_core.ml (task_status) | `.masc/tasks/backlog.json` (+`.last-good`), `tasks-archive.json` | 전이 + 수동 `masc_gc` | MCP, TUI, 키퍼 턴 |
| Goal | goal/ (phase·store·verification·due), workspace_goals.ml, goal_verification_agent.ml | `.masc/goals.json`, `goal_events.jsonl`, `tasks/goal_task_links.json` | outbox flush, verifier 에이전트 | MCP `masc_goal_*`, `/api/v1/goals/confirmation`, TUI |
| Schedule | schedule/ (domain·store·runner·service), server_schedule_consumers.ml | `.masc/schedules/` (요청 + signals + signal_keys.json) | maintenance 루프 tick | Keeper wake 큐, `masc_schedule_*` |
| HITL | keeper/keeper_gate.ml, keeper_approval_queue*.ml, keeper_contract/keeper_approval_queue_rules_types.ml, keeper_ask*.ml, Keeper_gate_mode | `.masc/gate/{mode,always-allowed,keeper-modes}.json`, 승인 큐, `.masc/keeper_ask/*.jsonl` | Auto Judge (exact lane `hitl_auto_judge`) | 도구 호출 직전 `Keeper_gate.decide`, TUI Gate 화면 |
| Access | auth/, types/types_auth.ml, server/server_auth.ml, tool/tool_catalog.ml | `.masc/auth/*.json`·`*.token` (0600) | token 만료·prune | 모든 HTTP 라우트 래퍼 4종, MCP 호출 |
| Multi Lane | lane_addon/ (20개), lane_registry/, exact_lane_run_registry.ml, fusion/ + fusion_core/ | `config/lane-addons/`, `exact-lane-runs-v6.jsonl` + payload 디렉터리 | run registry retention (lane마다 2,000) | `/api/v1/lane-addons/*`, 키퍼 lane 도구, TUI Lane 화면 |

연결: Goal drop → Task 취소 (workspace_goals.ml:800-909). Goal 확정 → Candle 지급 (`Candle_payout_owed.after_confirmation`, 경제 영역). Task 검증 제출 → verification 요청 → completion authority 판정 → Task Done. HITL gate → Auto Judge exact lane → 큐 행 상태. Board attention → exact lane `board_attention_exact`.

## 3. 기능 매트릭스

| 기능 | 정상 경로 | 경계·코너 | N-Tick 순환 | 관측성 | TUI 연결 | 테스트 | 판정 | 근거 | 제안 | 크기 |
|---|---|---|---|---|---|---|---|---|---|---|
| Board 게시·댓글·투표 | 불투명 ID 파싱 후 메모리+jsonl, 투표 flip 처리 | 가짜 comment id를 입구에서 거절, 자기 추천은 점수에만 반영 | 닫힘 (sweep+TTL, flusher) | Log+카운터 | 대시보드/TUI 읽기 | test_board* 126개 파일 | 정상 | board_core.ml, board_votes.ml:169-235 | 둠. 테스트 뒷문 2곳 지움 | S |
| Board flusher | 쓰기 시점 예약, 인박스 가득이면 롤백 | 최근 3번 수정 (#39989 #40488 #41459) | 닫힘 | drop 카운터 | - | 있음 | 정상(수리 중) | board_core_persist.ml:341-365 | 둠. 더 손대지 말고 근본 정리 확인 | S |
| Board attention 후보 원장 | 후보 기록 → 판정 → consume | 판정 `not_relevant`가 consume되지 않고 남음 | **열림** | 없음(크기 지표 없음) | quarantine 화면 | 있음 | **결함** | candidate.ml:1756-1766, live 187,062행 643MB | 종결 행 삭제/축약, not_relevant 즉시 종결 | M |
| Task 수명주기 | typed 전이, 검증 제출 → 권한 판정 | 훅 미설치면 fail-closed | 전이는 닫힘 | 전이 로그 | 있음 | 37개 파일 | 정상 | transitions.ml:86-330, hooks.ml:296-321 | 둠 | - |
| Task 보관/GC | 수동 `masc_gc days=N` | 자동 실행 없음 | **열림** | gc 결과 문자열 | - | 있음(수동 호출) | **결함** | tool_misc.ml:79, live 1209건 중 93% 종결 | 종결 즉시 archive 또는 maintenance 루프에 연결 | M |
| Task Hebbian 훅 | Done→strengthen, Cancel→weaken 이벤트 | 일꾼 수 x 이벤트 | 열림(읽는 곳 없음) | 활동 로그 21.8% | - | 훅 테스트만 | **결함(죽은 개념)** | workspace_core.ml:174-216 | 지움 | S |
| Goal 수명주기 | 7 phase, exhaustive 전이 | Paused/Blocked는 resume 대상 보존 | 닫힘 | 이벤트 outbox | 있음 | 28개 파일 | 정상 | goal_phase.ml:96-182 | 문자열 표 3벌 합침 | S |
| Goal drop → Task 취소 | 사유 필수, 미할당 Todo 취소 | 취소 실패는 응답에만, 재호출은 no-op | 열림(재시도 불가) | 응답 필드 | drop 사유 입력 | 취소 실패 경로 테스트 없음 | **결함** | workspace_goals.ml:867-909 | drop 재호출 시 고아 Todo 재시도 | S |
| Goal 증명·확정 | verifier → Awaiting_confirmation → operator 확정 | 4개 증거 일치 필요 | 닫힘 | 이벤트·알림 outbox | 확정 화면 | 있음 | 정상 | workspace_goals.ml:1093-1112 | 둠 | - |
| Goal 트리/제안 | 없음 | - | - | - | - | - | 미확인(존재하지 않음) | goal_store.mli:33-46 | 용어 정리 | - |
| Schedule 생성/수정/취소 | 4종 recurrence, cron 자체 파서 | DST 미지원을 명시 | 닫힘 | tick outcome 카운터 | 있음 | 19개 파일 | 정상 | schedule_domain.ml:365-760 | 둠 | - |
| Schedule 보류(self-clock) | Interval만 이전 미소비 시 보류 | 큐 읽기 실패는 fail-open | 닫힘 | 보류 시작 1회 로그 | 보류 목록 | 있음 | 정상 | server_schedule_consumers.ml:1265-1294 | 둠 | - |
| HITL 승인 큐 | phase 4종 파생 계산 | Require_human은 무기한 pending | 열림(사람 응답 대기, 상한 not checked) | audit 이벤트 | Gate 화면 | 21개 파일 | 의심 | rules_types.ml:150-179, gate.ml:779 | 만료/상한 확인 | M |
| Auto Judge | 요약+판정, Approve는 자동 해결 | 이름은 advisory, 동작은 결정 | 닫힘 | lane run 기록 | 근거·질문 표시(#41464) | 있음 | 의심(live 미실행) | gate.ml:565-590, live mode=always_allow | 이름 정리, live 검증 | S |
| 항상 허용 규칙 | (keeper, tool, 요청 해시) 정확 일치 + 만료 | 만료 규칙은 저장 유지 | 닫힘 | audit | 있음 | 있음 | 정상 | rules.ml, fingerprint.ml | 둠 | - |
| Ask (질문) | append-only 이벤트 | 동시 답변 락 없음 | 닫힘(작음) | 로그 | 있음 | 3개 파일 | 의심(P3) | keeper_ask_store.ml:132-166 | 파일 락 | S |
| 접근 제어(역할·권한) | Worker/Admin/Player x 10권한, 도구 미분류=CanAdmin | strict는 loopback 아닐 때만 | 닫힘 | auth 메트릭 | - | 45개 파일 | 정상(+의심 1) | types_auth.ml:334-368, tool_catalog.ml:653 | 권한 표 한 벌로 | S |
| MASC_AUTH_STRICT | Dry_run=Strict=동작 같음 | 풀리지 않는 토큰은 호출자 이름 유지 | 열림(6개월째 측정 단계) | would_reject 카운터 | - | 파서만 | **결함** | mcp_server_eio_caller_identity.ml:167-185 | 삭제하고 거절로 바꾸거나 코드 제거 | M |
| 쓰기 workspace 묶기 | `expected_workspace` 선택 | 라우트마다 다름 | - | 400/409 | TUI (#41501 OPEN) | 일부 | **결함** | workspace_utils_paths_backend.ml:34, routes_activity.ml:1355-1490 | `with_tool_actor_auth` 공통 처리 | M |
| Lane add-on 라우팅 | `source_access` 3종 typed | 경로 입력 작업공간에 가둠 | 닫힘 | lane run 기록 | 있음 | 20개 파일 | 정상 | routes_lane_addons.ml:51-56 | 같은 `within` 검사 하나로 | S |
| Exact lane 실행 기록 | lane당 2,000건 보존 | curator 1건 9MB | 닫힘(상한 큼) | run registry | 있음 | 있음 | 의심 | exact_lane_run_registry.ml:271-277 | curator 입력 중복 제거, 상한 낮춤 | M |
| Fusion | 심판·패널·sink, 결과 Lane 연결 | 거의 안 쓰임 | 닫힘 | fusion-runs.jsonl | 있음 | 19개 파일 | 미확인 | fusion_*.ml | 깊이 검토 필요 | - |

판정 수 (22행): 정상 10, 의심 4 (HITL 큐, Auto Judge, Ask, Exact lane 실행 기록), 결함 6 (Board attention 원장, Task GC, Hebbian, Goal drop 재시도, AUTH_STRICT, workspace 묶기), 미확인 2 (Goal 트리, Fusion).

## 4. 결함 목록

확신도 H/M/L. "고침" 제안은 가장 작은 변경 기준.

**P1**

D1. Board attention 후보 원장이 닫히지 않는다 (확신 H)
- 위치: keeper/keeper_board_attention_candidate.ml:1756-1766 (`compaction_ratio=2`, `needs_compaction`), 읽기 캐시 :1740-1745.
- 시나리오: 후보 행은 키퍼마다 복사되고(게시물 17.6k건 → 187,062행) 행마다 게시물 전문이 실린다. 만료·삭제 경로가 없다 (이 파일에서 `stale|expire|ttl|retention` 0건). 컴팩션 기준 "live"는 최신 행 전부라 consumed도 live다. 실측: consumed 114,952행 304MB, judged 34,635행 99MB, pending 33,262행 81MB, 합 643MB. 3일 넘은 pending 19,258 + judged 20,694. judged의 대부분(30,803행)이 `not_relevant`라 키퍼에게 전할 것이 없는데 판정만 하고 consume이 안 된다.
- 영향: 디스크 + 메모리(서버가 전체를 `state.latest`로 보관, 메모리 노트의 5~8GB heap 요인 후보. 측정은 not checked) + 매 쓰기마다 전체 재기록(컴팩션 시).
- 최소 수정: (1) `not_relevant` 판정은 judged를 거치지 않고 바로 consumed로. (2) consumed 행은 전문을 지우고 candidate_id와 판정만 남긴다(또는 N일 뒤 삭제). (3) 원인 확인 전에 3일 넘은 pending 원인(키퍼가 안 읽는지, 판정 worker가 안 도는지)을 먼저 본다.

**P2**

D2. Task GC가 수동뿐이라 backlog가 계속 커진다 (H)
- 위치: workspace/workspace_gc.ml:52 `gc`, 호출처는 tool_misc.ml:79 `masc_gc` 하나.
- 시나리오: 아무도 `masc_gc`를 안 부르면 Done/Cancelled가 backlog에 남는다. live: 1,209건 중 done 462 + cancelled 668 = 93%, 4.2MB, 마지막 archive 09-20, version 13,962. 전이마다 4.2MB 본파일 + 4.2MB `.last-good`를 다시 쓴다.
- 최소 수정: 종결 전이 시점에 archive로 옮기거나(전이 락 안에서) maintenance 루프에서 하루 한 번 `gc`를 호출.

D3. Goal drop이 Todo 취소에 실패하면 다시 시도할 길이 없다 (M)
- 위치: workspace_goals.ml:867-909 (`finish_goal_drop`), 특히 `let tasks = if changed then [...] else []` (:895).
- 시나리오: drop 커밋 후 `cancel_dropped_goal_todos`가 일부 실패(`cancel_failed`), 또는 프로세스가 중간에 죽는다. 같은 Goal에 drop을 다시 부르면 `Already Dropped → changed=false → tasks=[]`라 아무것도 안 한다. 미할당 Todo가 어느 Goal에도 속하지 않은 채 남는다. Task GC(D2)도 안 도니 정리 경로가 없다. 테스트에 `cancel_failed` 경로가 없다 (rg 확인).
- 최소 수정: `changed=false`여도 `dropped_goal_work`를 돌려 남은 `unclaimed`를 취소하게 하고, 실패 경로 테스트 1개.

D4. 쓰기 라우트의 workspace 묶기가 라우트마다 다르다 (H)
- 위치: workspace/workspace_utils_paths_backend.ml:29-34 (`[] -> Ok args`: 필드가 없으면 통과), server/server_routes_http_routes_activity.ml:1264/1295/1337 (board vote·post·comment만 검사), :1355-1385 (comment_vote 검사 없음), :1390-1425 (goal_transition 없음), :1427-1490 (schedule create/update/cancel 없음).
- 시나리오: TUI가 읽던 서버가 다른 작업공간 서버로 바뀐 뒤 Goal drop·일정 취소를 보내면 새 서버의 같은 id에 그대로 적용된다 (#41501 설명과 일치). 검사 함수는 하나인데 호출을 라우트마다 손으로 붙여서 4가지 모양이 됐다. N-of-M 패치 서명.
- 최소 수정: `with_tool_actor_auth` 래퍼가 body의 `expected_workspace`를 한 번 검사하고(쓰기 라우트는 필수), 개별 라우트의 호출을 지운다. #41501은 goal_transition 한 곳만 메우므로 N-of-M을 하나 더 늘리는 PR이다.

D5. `MASC_AUTH_STRICT`: 측정 단계가 끝나지 않았고 Strict는 구현이 없다 (H)
- 위치: auth/auth_strict_mode.ml:5-20, mcp_server_eio_caller_identity.ml:167-185.
- 시나리오: 토큰이 어떤 credential로도 풀리지 않으면 호출자가 준 이름을 그대로 쓴다. `Dry_run`과 `Strict`가 같은 동작(로그 + would_reject 카운터)이다. "Phase B PR-2가 거절한다"는 로그 문구만 있고 그 PR은 없다. 기본값과 모르는 값이 모두 `Dry_run`. 파일 주석은 하루 936건(2026-04-26 측정)을 근거로 든다. 이후 거절 전환 없이 카운터만 쌓는다 = telemetry-as-fix 서명 1.
- 완화 요인: 이후 `Auth.authorize_tool_v2`가 주체 이름에 대해 토큰을 다시 검증한다 (같은 파일 주석). 실제로 뚫리는지는 not checked.
- 최소 수정: Strict를 실제 거절로 구현하거나, 플래그와 카운터와 모드 3값을 지우고 현재 동작(이름 유지 + warn)만 남긴다. 이름이 같은 `http_auth_strict_enabled`와도 구분.

D6. Hebbian 훅은 아무도 읽지 않는 이벤트를 만든다 (H)
- 위치: workspace/workspace_core.ml:174-216, workspace_task_cleanup.ml:3-21.
- 시나리오: Task가 Done/Cancel될 때마다 작업 중인 모든 에이전트 수만큼 `hebbian.strengthen|weaken` 활동 이벤트를 쓴다. 읽는 코드는 없다(rg 전수). live 2026-10-06: 활동 로그 40,075행 중 8,720행(21.8%) = weaken 8,113 + strengthen 607. 하루 약 3.5MB, 활동 로그는 전체 487MB.
- 최소 수정: 훅 2개, `Workspace_hooks` 슬롯 2개, `working_agents` 호출, 테스트를 지운다.

D7. workspace_curator exact lane은 매 실행에 9MB를 보내고 69%가 실패한다 (M)
- 위치: exact_lane_run_registry.ml:271-277, live `exact-lane-run-payloads/workspace-curator-*`.
- 시나리오: 입력 9.28MB(사실 3,407개 6.5MB + 렌더된 프롬프트 3.37MB가 같은 내용 2회), 221건 중 성공 64 · 실패 153 · 취소 4. 실패 원인 예: glm-5.3-flash 429. 상한 2,000건이면 이 lane만 18GB. 프롬프트 3.37MB는 토큰으로 수십만 단위(환산은 모델마다 달라 수치는 not checked).
- 최소 수정: 실패한 run은 입력 payload를 보존하지 않거나 해시만 남긴다. curator 입력을 사실 상한으로 자른다 (curator 도메인은 memory 감사자 영역, 결정은 그쪽과).

**P3**

D8. 테스트 전용 변형이 production에 노출돼 있다 (H)
- `Goal_store.update_goal_if_phase`(goal_store.ml:717): production caller 0, test만 13곳. `upsert_goal`/`upsert_goal_with_revision`: actor가 없으면 감사 이벤트를 안 쓰는 경로인데 production은 `upsert_goal_with_events`만 부른다 (workspace_goals.ml:270). 테스트는 production이 안 타는 경로를 검증한다.
- `Board_core_persist.reset_sweep_schedule_for_test`, `sweep_schedule_timestamps_for_test` (:390-399), `Board_votes.reset_global_for_test` (:936), `Server_auth.For_testing` (:1310-). 리포 전체 `module For_testing` 218개. 체크리스트 6번.

D9. 권한 표가 두 벌이다 (H)
- types/types_auth.ml:334-368: `permissions_for_role`(리스트)와 `has_permission`(match)가 같은 표를 따로 쓴다. 주석이 "parallel"이라 스스로 인정. match는 exhaustive지만 리스트는 아니라서 새 권한이 리스트에서만 빠질 수 있다. 하나(match)에서 리스트를 만들거나 리스트를 지운다.

D10. `Keeper_always_allow` 플래그가 Keeper별 모드 덮어쓰기보다 먼저 통과시킨다 (M)
- keeper/keeper_gate.ml:2208-2213. 주석(:2216-2219)이 말하는 "Keeper를 더 엄격히" 의도와 순서가 반대다. live에서 해당 Keeper는 sangsu 하나라 영향 작음.

D11. Ask 중복 응답 (M)
- keeper/keeper_ask_store.ml:132-166: 락 없이 "읽고 → 확인 → append". 두 응답자가 동시에 답하면 둘 다 Ok를 받고 먼저 쓴 쪽만 반영된다.

D12. 사실상 죽은 `implementation_status` (H)
- tool/tool_catalog.ml:24-33,105,690-694: production에서 `Real`만 쓰인다. `Simulation|Placeholder|Adapter` 분기, `MASC_PLACEHOLDER_TOOLS_ENABLED`, 프롬프트 상수 2개, 테스트가 딸려 있다.

D13. 카르마를 요청마다 전부 다시 계산한다 (M)
- board/board_votes.ml:1085-1098 `build_karma_ledger`: `/api/v1/karma`(공개 GET, routes_activity.ml:1491) 요청마다 store 락을 잡고 vote_log 전체를 순회한다. live 투표 85KB라 지금은 작다.

D14. `package-preview` GET이 읽기 권한으로 컨테이너 이미지 조회를 일으킨다 (M)
- server/server_routes_http_routes_lane_addons.ml:127-135, 155-157.

D15. 수명주기 문자열 표 3벌 (H)
- goal/goal_phase.ml: `Kind.to_string/parse`, `of_string/parse`, `action_to_string`+`Public_action` (:13-35, :88-103). 같은 대응을 variant마다 따로 적었다.

## 5. 낭비

| 무엇 | 크기 | 어디 | 고침 |
|---|---|---|---|
| Board attention 후보 원장 (게시물 전문이 키퍼마다 복사, 종결 행 보관) | 디스크 643MB / 187,062행. 서버 메모리에도 전체 상주(측정 not checked) | `.masc/board_attention_candidates/`, candidate.ml:1740-1766 | D1 |
| `exact-lane-runs-v5.jsonl` (v6로 바뀐 뒤 안 읽는 파일) | 743MB | `.masc/` (09-15 이후 쓰기 없음, 코드는 v6만 읽음 exact_lane_run_registry.ml:423) | 운영자 확인 후 삭제 |
| `exact-lane-run-payloads` 중 workspace-curator | 222건 1.34GB (한 건 9MB). 상한까지 가면 18GB | `.masc/exact-lane-run-payloads/workspace-curator-*` | D7: 실패 run 입력 미보존, 입력 중복 제거 |
| `lane-addons-archive/` | 514MB (코드 참조 0) | `.masc/lane-addons-archive/bindings-never-ran-20260925` | 운영자 확인 후 삭제 |
| Hebbian 활동 이벤트 | 하루 약 3.5MB (10-06 기준 활동 로그의 21.8%) | workspace_core.ml:174-216 | D6 지움 |
| Task backlog 전체 재기록 | 전이마다 4.2MB + 미러 4.2MB (93%가 종결 Task) | `.masc/tasks/backlog.json` | D2 |
| 회전된 Board 백업 4개 | 42MB (09-14, 09-19 이후 변화 없음) | `.masc/board_{posts,comments}.jsonl.{1,2}` | 운영자 확인 후 삭제 |
| 단일 GLM flash 슬롯에 세 lane 몰림 | curator 429 실패 153건 (69%), 실패해도 입력 9MB 보관 | config/runtime.toml:89-100 | 슬롯 분리 또는 curator 빈도 조절 (결정은 운영자) |
| 카르마 전체 재계산 | 요청마다 vote_log 순회 + store 락 | board_votes.ml:1085 | 변경 시점에 갱신 (지금 크기에서는 낮은 우선) |

가정: 토큰 낭비 수치는 이 영역에서 직접 측정하지 못했다. curator 렌더 프롬프트 3.37MB는 글자 수이고 토큰 수가 아니다.

## 6. 용어·결합

한 이름 두 뜻:
- **Gate**: (a) 도구 승인 판정 `keeper_gate.ml` + `Keeper_gate_mode`(always_allow/auto_judge/manual), (b) `lib/gate/` Slack·Discord·iMessage 채널 연결, (c) `workspace_goals.ml:413 gate_verdict` (Goal 증명 판정). "Gate 화면"이 (a)인지 (b)인지 코드만 보고 못 가른다. 제안: (b)는 `channel connector`, (c)는 `proof_verdict`.
- **strict**: `http_auth_strict_enabled`(loopback 아닐 때 인증 강제, server_auth.ml:23)와 `MASC_AUTH_STRICT`(Off/Dry_run/Strict, 토큰 미해결 처리)는 다른 것이다. D5로 후자를 지우면 해소.
- **advisory_judgment** (Approve/Deny/Require_human): 이름은 자문인데 `Approve`/`Deny`는 `resolve_judgment`로 곧장 결정이 된다 (keeper_gate.ml:565-590). `judge_decision` 쪽이 맞다.
- **Auto** (도구 승인 intent)와 **Auto_judge** (Gate 모드): 글로서리 2020행이 이미 "다른 값"이라고 적어 둔다. 접두어가 같아 헷갈린다.
- **verification**: Task 검증 요청(`verification_id`)과 Goal 증명(`Goal_verification`)이 둘 다 verifier·completion authority를 쓰는데 저장소는 따로다. 합칠 이유는 없고 이름만 구분: Task 쪽 `completion review`, Goal 쪽 `proof`.

의뢰서와 코드가 다른 개념:
- **Goal tree, proposal**: 코드에 없다 (goal 타입에 parent 필드 없음, goal_store.mli:33-46). 글로서리에도 없음. 표시용 묶음이거나 계획된 기능으로 보인다. 확인 필요.
- **Goal phase**: 글로서리(docs/spec/00-glossary.md:1787-1796)는 5개로 적는데 코드는 `Paused`/`Blocked`가 더해진 7 kind다 (#41151, goal_phase.ml:1-30). 글로서리가 뒤처짐.
- **Hebbian**: 코드에만 있고 글로서리에는 없다. 학습 기능 같은 이름인데 하는 일은 로그 쓰기뿐.

결합(분리해도 손실 없음):
- `keeper_approval_queue.ml`(3,182줄)은 큐 상태, 파일 저장, 요약 시도 상태기계, exact 시도 전이를 한 파일에 둔다. `_codec`, `_state`, `_projection`, `_result`, `_exact_transition`으로 일부 쪼갰으나 본체가 여전히 크다. 요약 시도 상태기계(`summary_attempt_disposition` 6값 x `summary_status` 4값 x `exact_attempt` 2값)는 별도 모듈 후보.
- `Workspace_hooks`는 Atomic 슬롯 36개의 서비스 로케이터다. 의존 방향을 뒤집는 장치로는 타당하나 기본값이 permissive인 슬롯(`schedule_wake_target_registered_fn` = `Ok true`)이 섞여 있다. 슬롯을 "미설치면 에러" 한 가지로 통일.
- Board와 Board attention: `lib/board/`(5.5k줄)와 `keeper_board_attention_*`(9.3k줄)가 따로 있다. attention은 Board의 파생 읽기 모델인데 키퍼 모듈 안에 있어서 Board 쪽 삭제·TTL을 모를 수 있다. 후보가 가리키는 게시물이 지워져도 후보 행이 남는지는 not checked (D1의 원인 후보).

## 7. 지울 것

1. Hebbian 훅 2개와 `Workspace_hooks` 슬롯 2개, `working_agents` 호출, 활동 이벤트 종류 2개 (D6).
2. `Auth_strict_mode`의 `Strict` 변종 또는 모듈 전체 (D5).
3. `Tool_catalog.implementation_status`와 `Simulation|Placeholder|Adapter`, `MASC_PLACEHOLDER_TOOLS_ENABLED`, `tool_help_constraint_{placeholder,simulation}` (D12).
4. `Goal_store.update_goal_if_phase`, `upsert_goal`, `upsert_goal_with_revision` (테스트 전용 변형, D8). 테스트는 `upsert_goal_with_events`로 옮긴다.
5. 테스트 뒷문: `reset_sweep_schedule_for_test`, `sweep_schedule_timestamps_for_test`, `reset_global_for_test` (D8).
6. `permissions_for_role` 리스트 또는 `has_permission` match 둘 중 하나 (D9).
7. `lib/board_*.ml` 1줄 shim 8개 후보. `include_subdirs` 구성 때문에 단독 삭제 가능 여부는 not checked.
8. 데이터: `exact-lane-runs-v5.jsonl`(743MB), `lane-addons-archive/`(514MB), 회전된 Board 백업 4개(42MB) — 운영자 확인 후.
9. `handle_goal_transition`의 `Already`/`Move_to` 두 갈래에 똑같이 복사된 Reopen/Pause/Resume/Block/Unblock/Drop 처리 (workspace_goals.ml:1040-1085).
10. `lane_addon_catalog.within`과 `Exec_policy_paths.is_within_dir` 중 하나 (경로 가두기 검사 2벌).

## 부록 B. 이번 주 변경 판단 메모
- #41459 (Board flusher CAS 상한 제거): 근거 없던 재시도 상한을 지운 정리. 방향 맞음. 같은 영역 3번째 수정(#39989 → #40488 → #41459).
- #41455 (증명 요청이 상태기계에서 다음 상태를 받음): D-3의 call-site 패치 6건을 구조로 흡수. 좋은 방향.
- D-1 Lane 크기 검사 제거 6건 (#41269 #41281 #41287 #41279 #41290 #41259): 결과를 못 바꾸는 검사를 지우는 정리라 방향 맞음. 앞서 상한을 넣은 이유(실제 사고인지 예방인지)는 not checked.
- #41501 (OPEN): goal_transition 한 곳만 `expected_workspace`를 필수로 한다. D4와 같은 N-of-M 패치. 공통 래퍼로 대체 권장.
- #41464 (human_required 행에 Auto Judge 근거 표시): `phase_of_disposition_and_summary`는 `Require_human`일 때만 `Phase_human_required`를 낸다 (rules_types.ml:150-179). 서버 계약은 맞다. live가 `always_allow`라 현재 해당 행은 없다.
