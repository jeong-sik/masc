# E-tui 감사: 운영자 화면 (TUI + 웹 대시보드)

기준: origin/main fb5344a25a (2026-10-07 14:03 KST). 코드는 `E-tree/` 스냅샷과 `git show fb5344a25a:` 로 읽음.
PTY 테스트는 실행하지 않음. 라이브 수치는 `~/me/.masc/logs/masc-tui-*.log` (2403개 파일, 1초 넘게 걸린 요청만 기록됨, PTY 테스트 실행분 포함).

## 1. 영역 지도

TUI (OCaml, 479개 파일 in bin/, 135k줄)
- `bin/masc_tui.ml` 27,520줄: 메인 루프, 모든 launch_*/apply_* 읽기, 키 처리. `masc_tui_types.ml` 12.5k줄(상태 mutable 필드 675개), `masc_tui_render.ml` 14.2k줄.
- 읽기 경로: `masc_tui_http.ml`(fetch) -> `masc_tui_loader.ml`(load_*) -> `lib/tui_decode*.ml`(JSON 디코더, 서버와 공유하는 타입 일부 재사용) -> `apply_*_load` -> state.
- 갱신 루프(masc_tui.ml:27280 근처): 기본 2초(`--refresh`, masc_tui.ml:500). 한 번에 `start_http_refresh`(전체 묶음) + 화면별 개별 읽기. 화면이 바뀌면 `surface_needs_delta`(masc_tui_types.ml:2792)로 필요한 읽기만 즉시 보냄.
- 권한 모델: `workspace_authority`(정수 세대) + `detail_read_authority`(unit ref). 서버 신원(/health)을 읽을 때마다 바뀌면 진행 중 읽기를 취소하고 상태를 비움 (`apply_server_identity_reading` masc_tui.ml:10801, `withdraw_keeper_workspace_presentation` :10441).

웹 대시보드 (TypeScript/Preact, dashboard/src 1,508개 파일, 약 206k줄, 테스트 698개)
- `src/api/*.ts`(fetch + normalize), `src/store.ts` 등 signal 스토어, `src/components/*`. SSE 타입은 생성(`schemas/sse_event_generated.ts`), REST 타입은 손으로 미러링(`types/*.ts` 3.8k줄).
- 서버 쪽: `lib/server/server_routes_*` 의 `/api/v1/dashboard/*` 라우트 93개.
- `dashboard/evidence/` 에 PR별 증거 파일 414개, 13.8MB가 커밋돼 있음 (png 70, json 92, txt 105, log 26 ...).

## 2. 7일 흐름 (committer date KST, `bin/masc_tui*`+`lib/tui_*` / `dashboard/src`)

- D-7~D-6 (09-29 15:27 ~ 09-30): TUI 45커밋(fix 27), 대시보드 8. TUI 화면을 "Work/Usage/Lanes/Memory/Code" 단위로 하나씩 통합하는 fix가 줄줄이(#40296~#40347). 대형 파일에서 `masc_tui_render_approvals` 등으로 렌더러 분리 시작.
- D-6~D-5 (09-30 ~ 10-01): TUI 64커밋(fix 44), 대시보드 14. Keeper 신원 흐름이 늦은 응답에도 유지되게(#40146), Item/포트레이트를 현재 workspace에 묶기(#40393), 채팅 SSE 디코더 통일(#40462), Candle 지갑(#40024).
- D-5~D-4 (10-01 ~ 10-02 19시): 가장 큰 날. TUI 200커밋(fix 93, Merge 38+15, `Rebase PR #...` 7), 대시보드 53, 변경 +13.8k/-9.5k줄. 스택 PR을 한꺼번에 main에 합치면서 "main이 컴파일 안 됨" 복구가 연달아 나옴 (#40555, #40633, #40635, #40657, #40788). Memory/Librarian 읽기를 workspace 권한에 묶는 수정(#40173, #40827).
- D-4~D-3 (10-02 19시 ~ 10-03 17시): TUI 15커밋, 대시보드 0. 빌드 복구(#40978), Lane 읽기를 신원 확인 뒤에 재개(#40693, #40696, #40707).
- D-3~D-2 (10-03 ~ 10-04): TUI 26커밋(fix 20), 대시보드 15. Lane 모델 교체/검색, 계정 로그인, Usage 계정 카드(#41106~#41117), 또 한 번 main 컴파일 복구(#41147, 셋이 "리뷰만 하고 합친" PR의 충돌).
- D-2~D-1 (10-04 ~ 10-05 13:57): TUI 6커밋. 조용한 날.
- D-1~HEAD (10-05 ~ 10-07): TUI 47커밋(fix 25), 대시보드 30. 대시보드 516파일 +35.4k/-1.0k줄이 여기. 그중 증거 파일(dashboard/evidence)이 408파일 24.1k줄(68%), 실제 소스는 `src/components` 약 8k줄 + `src/lib` 2.9k + `src/api` 1.4k. 내용은 Lane Add-ons 스택(#41102~#41212, 10-06 15:52:40~52 에 30여개가 12초 안에 합쳐짐): All Lanes 인벤토리, Exact/Browser/MSX/DOS "활동 켜기/끄기"와 초안 저장, 패키지 설치. 10-07 오전에는 TUI 권한 복구를 한 함수로 모음(#41478), Gate 행에 Auto Judge 근거 표시(#41464), 안 쓰는 TUI 함수 삭제(#41471, #41468).

반복/뒤집기(churn) 신호
- "main 컴파일 복구" 커밋 7개 (5일, TUI/대시보드 범위): efa4347615, bcd6d39822, c7618419e8, 483d1123d7, 6458f92ef3, c62ddd7638, 03e8825ff8. 스택 PR을 리뷰만 하고 CI 없이 합치는 운영(MASC 정책)의 비용.
- 신원/권한으로 버려진 읽기를 다시 거는 수정이 6번: #40173(Item), #40693(Lane), #40696(로그인 대기), #40707, #41098(채팅 초안), #41478(전체 모음). 뿌리는 5절 D-1.
- 대시보드에서 "workspace별로 격리" 수정 5개 (#41153 Add-ons, #41161 shared runtime, #41182 runtime observation, #41194 Settings Runtime, #41210 Lane inventory). 같은 종류의 N-of-M.

## 3. 기능 매트릭스

범례: 판정 = 정상 / 의심 / 결함 / 미확인. 크기 S(한 함수) M(한 PR) L(스택). "TUI 연결"은 TUI가 읽는 엔드포인트. 테스트는 test/ 안에서 이름으로 찾은 것만 적음.
TUI가 부르는 `/api/...` 경로 143개를 서버 라우트와 대조: 서버에 없는 경로 0개 (문자열 존재 확인 수준, fb5344a25a:lib). 연결 누락은 없음.

| 기능 | 정상 경로 | 경계·코너 | N-Tick 순환 | 관측성 | TUI 연결 | 테스트 | 판정 | 근거 | 제안 | 크기 |
|---|---|---|---|---|---|---|---|---|---|---|
| Gate / HITL (Approvals) | 2초마다 `/dashboard/gate` 읽기 후 행 표시, #41464로 human_required 행에 Auto Judge 근거 표시 | 행 하나라도 phase 모름 / human_required인데 요약 없음 -> 스냅샷 전체 Error, `gate_pending <- []` (masc_tui.ml:15698~15702, 15700에서 비움). 웹은 행 단위 violation으로 격리(dashboard/src/api/dashboard-gate.ts:471) | 닫힘. 다만 오류가 한 번 나면 목록이 비고 다음 성공 때 복구 | 오류 문구에 "gate load failed: ..." 접두. 목록이 사라진 이유는 제목에 "Gate queue unread" 로만 | /dashboard/gate (+ /health 프로브 2번) | test_tui_decode.ml 에 phase/요약 케이스. 읽기 실패 시 행 유지/삭제를 확인하는 테스트는 못 찾음 | 결함 | D-1, D-2, tui_decode.ml:4016~4050, 4080~4115, 4153~4170 | 행 단위 격리(웹과 같은 violation 목록)로 바꾸고, Error 시 마지막 행 유지 | M |
| Approvals 묶음 (confirm queue / held calls / Gate / asks) | 4개 목록을 `approval_items`로 합침 (approvals_model.ml:22) | `Approval_stale`(행 유지+오류) 설계는 Gate에서 도달 불가: Error가 observed=false로 만들기 때문. confirm queue는 Error 시 스냅샷 삭제(masc_tui.ml:9906) | 닫힘 | 제목에 ", Gate queue unread" 식 표시. 주석(approvals_model.ml:56)은 "행을 유지"한다고 적어 코드와 모순 | /operator, /keepers/tool-approvals, /dashboard/gate, /keepers/asks | test_tui_approval_authority.ml, test_tui_chat_gate_row.ml | 의심 | 4절 D-1 | 목록 4개의 오류 정책을 하나로 통일 (유지+stale 표시) | M |
| Goal / Planning (Work) | `/dashboard/planning` + `/dashboard/goals`; 합계는 서버 rollup 사용. #41357(드롭 사유 필수)·#41151(Pause/Block) TUI 키까지 연결됨 | 읽기 실패 시 `planning <- None`, 상세 화면이면 목록으로 되돌리고 스크롤 0 (masc_tui.ml:10185). 합계 분모에서 Paused/Blocked 빠진 버그가 #41462에서야 수정됨 | 닫힘 | planning_error 표시 | /dashboard/planning, /dashboard/goals, /dashboard/goals/detail | test_tui_planning_summary_rows.ml | 의심 | #41462, apply_planning_load | 오류 시 마지막 값 유지. 위상(phase) 목록을 Goal_phase에서 파생 (4절 D-4) | M |
| Task / Verification | Work 안에서 Goal 먼저(#41368). Verification 화면은 2초마다 200행 큐를 다시 읽음 (masc_tui.ml:27320) | 한 행 디코드 실패 시 전체 실패 (decode_list, tui_decode_fields.ml:192) | 닫힘 | 오류 문구 | /verification/requests?view=awaiting&limit=200 | 미확인 | 미확인 | - | - | - |
| Schedule | 모든 화면에서 2초마다 스케줄 목록(일정 띠(agenda strip)용) | 한 행/한 wake 디코드 실패 -> 목록 전체 실패, 마지막 값은 유지 (masc_tui.ml:15103~15125). 서버는 20행으로 자름 | 닫힘 | schedules_error | /dashboard/scheduled-automation | test_tui_*schedule* 다수 | 의심 | 5절 W-2 | 읽기 주기를 늦추거나 서버가 next wake 한 줄만 주는 요약 엔드포인트 | M |
| Board | Board 화면에서만 목록+hearths 읽기, 상세는 2초 갱신 | 실패하면 기존 목록 유지 (board_updates.ml:49). 정상 | 닫힘 | board_list_error | /board, /board/hearths | 있음 | 정상 | - | 둠 | - |
| Keepers / turns / chat | 매 tick 로스터+turns, 채팅 화면이면 history, SSE로 스트림 | turns 실패 시 마지막 값 유지(masc_tui.ml:15676). 로스터 실패 시 로스터와 Item 계정을 비움(의도, 주석 있음). 신원 읽기 한 번 실패하면 채팅 초안 보관+대기열 정지(5절 D-1) | 닫힘 (세대 번호로 낡은 응답 버림) | 오류 notice | /keepers/composite, /keepers/turns, /keepers/{k}/chat/history, SSE | test_tui_keeper_chat_* 다수, PTY | 의심 | D-1 | 신원 읽기 정책 정리 | L |
| Workspace 권한 / 읽기 재개 | #41478: 신원이 바뀌면 `resume_reads_after_authority_change`가 tick 부가 읽기(turns, schedules, 로그인 폴, 채팅 history)와 Lane, 상세를 다시 보냄 | 전체 갱신 경로(:13842)와 범위 갱신 경로(:10945) 둘 다 호출. 범위 경로는 Gate/held-call을 다시 걸지 않음(커밋 메시지는 "건드릴 필요 없다"고 주장) | 닫힘 (다음 tick이 보충) | 이벤트 없음 | /health | 단위 테스트 없음, Answering PTY 3개로만 확인 | 의심 | D-2, D-3 | 단위 테스트 추가. 읽기 목록을 한 표로(이미 launch_tick_side_reads) | S |
| Librarian / Memory | Memory 화면 진입 시 health 읽기 + tick 갱신. 전체 보기("*")는 Keeper마다 facts를 직렬로 읽음 (masc_tui.ml:4531~4551, 로스터 114개 규모에서 N+1) | 한 Keeper의 facts에 모르는 category 있으면 그 Keeper 전체 실패(의도, 주석). 병합 스냅샷에 `mos_revision = 1` 같은 가짜 값 | 열림 아님. 진입 때 한 번 | "N of M keepers not read" | /dashboard/keeper-memory-health, /keepers/{k}/memory-facts | test_tui_memory_facts_authority_pty.py | 의심 | W-3, D-5 | 서버가 fleet facts 한 번에 | M |
| Lanes / Add-ons | Lanes 화면 2초마다 인벤토리 읽기. Add-ons 창이 열려 있고 편집 중이 아니면 2초마다 `/lane-addons` 전체 읽기 | row_owner가 `lane_id` 접두어(`instance.id ^ "/"`)로 소속 판정 (lane_addons.ml:256, :613). 신원 읽기 전 Lane 읽기는 #41478로 재개 | 닫힘 | 상세 실패/인벤토리 실패 구분(`lane_addons_failure`) | /lanes, /lane-addons, /lane-addons/slice | test_tui_lane_initial_authority.py 등 | 의심 | D-6 | 소속을 타입 필드로 | M |
| Candle / Items / Portrait | 로스터 응답 안에 Candle 관측이 같이 옴. Item 읽기는 신원 바뀌면 무효화(#40173) | 로스터 읽기 실패 -> Candle 관측도 Error로 바뀜(결합, masc_tui.ml:10136). 서버 `state_ready=false`면 Candle None | 닫힘 | candle_observation Error 문구 | /keepers/composite, Item 엔드포인트 | test_tui_item_workspace_authority_pty.py | 미확인 (구조만 읽음) | - | 로스터와 Candle 분리는 용어 5절 참고 | - |
| Usage / providers | Usage(Metrics) 화면에서만 roster, transport, quota(`/runtime/resolved`), keeper-usage, provider-history, account-emails를 2초마다 읽음 | provider history가 "loading"이면 Error로 바뀌어 차트가 사라짐 (loader.ml:1324). `/runtime/resolved`는 한 응답을 디코더 2개로 두 번 파싱 | 닫힘 | 각각 *_error | /runtime/resolved, /dashboard/keeper-costs, /dashboard/provider-usage-history, /setup/account-emails | test_tui_*usage* 있음 | 의심 | W-4 | 계정 이메일·provider history는 변경 빈도가 낮으니 tick에서 빼기 | S |
| 웹 대시보드 Gate | 행 단위 normalize + violation 목록 + 서버 개수 불일치 검사 | `hasOnlyKeys`로 필드를 닫아서 서버가 필드 하나 추가하면 그 행이 violation (api/board.ts:288~330). 서버 불변식(disposition x exact_attempt x summary 쌍) 60줄을 클라이언트가 다시 구현 (board.ts:350~417) | 닫힘 | violation 개수 표시 | /api/v1/dashboard/gate | dashboard 테스트 있음 | 의심 | W-5 | 불변식 검증은 서버만. 클라이언트는 모양만 | M |
| 웹 대시보드 Lane Add-ons 스택 | All Lanes 인벤토리, 활동 초안 저장 | 패밀리별 observation 모듈 3개가 이름만 다른 복사본 (exact/browser/machine-lane-observation.ts, 각 16~17줄) | 닫힘 | 영수증 | /api/v1/lane-addons, /runtime/config | 있음 | 의심 | 6절 | 합침 | S |

(Task/Verification, Candle/Items/Portrait 일부는 시간상 구조만 읽음. "미확인" 표시.)

## 4. 결함 목록

### P1 없음. P2 4건, P3 6건.

**D-1 (P2) 신원 읽기 한 번 실패 = 권한 전체 철회. 복구 패치 6개가 증상 수리**
- 위치: `bin/masc_tui_types.ml:141~143` (`Error _ -> Workspace_identity_unread`), `bin/masc_tui.ml:10801~10850` (unread면 Gate/Board/Approvals/Asks/Planning/Roster를 지움), `:10852~` (`server_workspace_matches ~expected Error` = false 라서 `workspace_authority` 세대 증가, 취소 콜백 실행, `keepers <- []`, `withdraw_keeper_workspace_presentation` 호출).
- 시나리오: 서버가 바쁜 2초 tick에서 `/health` 한 번이 타임아웃 (tick마다 3번 읽는 중 하나만 실패해도 됨: 앞, 범위 읽기 안, 뒤) -> `load_http_surfaces`가 `Refresh_workspace_unconfirmed`를 돌려줌 (:10323~10365) -> `apply_workspace_unconfirmed` -> 신원 Error. 서버는 그대로인데 TUI는 "workspace가 바뀜"으로 처리: 채팅 입력창 비움(초안은 저장), 대기 중 Keeper 입력 정지와 "Workspace changed: unsent Keeper inputs retained..." 안내 (:10590~10600), 진행 중 읽기 전부 취소, 목록 비움. 다음 tick에 복구되지만(입력창 초안을 되살리는지는 확인 못 함) 그동안 화면이 깜빡이고, 복구마다 5절의 "다시 거는" 코드가 필요.
- 근거: 이 흐름을 메우는 커밋이 #40173, #40693, #40696, #40707, #41098, #41478로 5일에 6개. 라이브 로그에서도 `/health`가 1초 넘게 걸린 기록이 7일간 5,838건, 최대 27초 (masc-tui-*.log, PTY 테스트 포함이라 실사용 비율은 불명).
- 확신: 코드 경로 high. 발생 빈도는 low~medium(서버 부하 의존).
- 최소 수정: "읽기 실패"와 "다른 workspace 확인"을 다른 타입으로 분리. 실패는 마지막으로 확인된 신원을 유지한 채 `connection_status`만 Degraded로. 권한 세대는 서버가 다른 workspace/프로세스라고 확인했을 때만 올림.

**D-2 (P2) Gate 읽기 실패 때 목록을 비움. 행 하나가 전체를 막음. 웹은 반대 정책**
- 위치: `masc_tui.ml:15698~15702`, `lib/tui_decode.ml:4153~4170` (`decode_gate_snapshot`이 행마다 `let*`), `:4016~4050`.
- 시나리오 A: 서버가 새 phase 문자열을 추가하거나, 저장된 큐 행 하나가 `human_required`인데 `summary_status`가 available이 아님 -> 스냅샷 전체 Error -> `gate_pending <- []`. 사람이 결정해야 할 다른 행 전부 사라지고 제목에 "Gate queue unread". #41464가 이 실패 조건을 새로 추가함("a human_required gate row carries no Auto Judge summary").
- 시나리오 B: 일시적 타임아웃 한 번에도 같은 결과 (held-call과 asks는 마지막 값을 유지하는데 Gate만 비움).
- 모순 증거: `bin/masc_tui_approvals_model.ml:56~60` 주석은 "Gate 폴은 Ok일 때만 행을 바꾼다"고 쓰고, `Approval_stale` 분기는 observed=true + error 조합을 가정하지만, Error 가지가 `gate_snapshot_observed <- false` 로 만들어서 Gate 쪽 `Approval_stale`은 도달 불가.
- 웹은 `dashboard/src/api/dashboard-gate.ts:466~485`에서 행 단위 violation으로 격리하고, `#31695: One undecodable history row must not blind the operator to the open-Gate count` 라는 주석까지 있음. 같은 서버 응답을 두 화면이 반대 정책으로 읽음.
- 확신: high (코드 직접 확인). 서버가 human_required를 요약과 같은 함수로 만들기 때문에(`keeper_approval_queue_rules_types.ml:155~176`) 시나리오 A의 현재 발생 확률은 낮음. B와 새 phase 추가는 현실적.
- 최소 수정: (1) Error 가지에서 `gate_pending` 유지, error만 설정. (2) 행 디코드 실패는 그 행만 "읽지 못함" 행으로 표시. (3) phase 문자열 파서는 서버의 `approval_queue_phase_of_yojson_with_error`(keeper_approval_queue_rules_types.ml:127~)를 재사용하고 TUI 쪽 `Gate_*` 4개 variant는 서버 타입을 그대로 가져다 쓰기.

**D-3 (P2) Planning 읽기 한 번 실패하면 열어둔 Goal 상세가 목록으로 튕김**
- 위치: `masc_tui.ml:10185~10192` (`apply_planning_load` Error: `planning <- None; planning_mode <- Planning_list; planning_scroll <- 0; goal_action_pending <- None`).
- 시나리오: Work 화면에서 Goal 상세를 읽는 중 `/dashboard/planning`(수십 KB, masc_tui_types.ml:2706 주석) 응답 한 번이 타임아웃 -> 상세가 닫히고, 진행 중이던 Goal 액션 대기 표시도 지워짐. Board와 Schedule은 같은 상황에서 마지막 값을 유지하는데 Planning만 다름.
- 확신: high(코드), 발생 빈도 medium.
- 최소 수정: Error에서는 `planning_error`만 설정하고 나머지는 유지. 이미 `Planning_selection.reconcile`이 있으니 다음 Ok에서 맞춰짐.

**D-4 (P2) 웹 쪽에도 같은 모양: Gate 불변식 재구현 + 닫힌 키 목록**
- 위치: `dashboard/src/api/board.ts:288~420`. `hasOnlyKeys`로 키 집합을 닫고(서버가 필드 하나 추가하면 그 행이 violation), disposition x exact_attempt x summary 쌍 검증 60줄을 클라이언트가 따로 가짐.
- 시나리오: 서버가 `summary_attempt_disposition`에 코드 하나 추가하거나 `exact_attempt` 필드를 늘리면, 웹은 해당 Gate 행을 "undecodable"로 격리. 운영자가 웹에서 그 승인 요청을 못 봄.
- 확신: medium (서버/클라이언트 업그레이드 시점이 같아서 현재 문제는 없음).
- 최소 수정: 쌍 검증은 서버가 책임지고(이미 `phase_of_disposition_and_summary`가 서버에 있음), 클라이언트는 필드 모양과 phase만 읽음.

**D-5 (P3) 메모리 읽기 가드가 같은 값끼리 비교**
- `masc_tui.ml:4474`, `:4492`: `same_workspace_identity state.server_identity state.server_identity`. 자기 자신과 비교라 "신원이 있고 booting 아님"만 검사함. `Workspace_identity_match` 인지는 검사하지 않음. 복붙 실수로 보임 (의도였다면 `server_authority_ready` 사용).
- 시나리오: 신원이 mismatch(다른 workspace 서버)여도 Memory 화면은 health/input을 읽음. 응답은 `launch_workspace_request`의 권한 토큰이 거르므로 잘못된 데이터가 화면에 남을 가능성은 낮음 -> 불필요한 요청과 혼란스러운 코드.
- 확신: high(코드 사실), 영향 low. 수정: `server_authority_ready state` 또는 identity match 조건으로 교체.

**D-6 (P3) 범위(scoped) 갱신은 권한 이동 뒤 Gate/held-call을 다시 걸지 않음**
- `masc_tui.ml:10945` 부근 `apply_http_scoped_refresh_success`: `resume_reads_after_authority_change`는 호출하지만 `launch_gate_snapshot_load`와 `launch_keeper_tool_approvals_load`는 전체 갱신 경로(:13890~13899)에만 있음. #41478 커밋 메시지의 "Gate is untouched: it is read after every refresh validates identity"는 전체 갱신에만 맞음.
- 시나리오: 부팅 직후 화면 전환 때문에 범위 갱신이 첫 신원을 확정하면, Gate 목록은 다음 전체 tick(기본 2초, `--refresh`를 키우면 그만큼)까지 "unread". 확신 medium, 영향 low.
- 수정: 두 launch를 `resume_reads_after_authority_change` 안으로 옮겨서 "읽기 재개 목록"을 한 곳에.

**D-7 (P3) 메인 파일 크기와 수작업 초기화**
- `masc_tui.ml` 27,520줄, `masc_tui_types.ml` 12,563줄(state mutable 675개), `masc_tui_render.ml` 14,196줄. 프로젝트 기준(300줄 이상 분리 검토)의 90배.
- `withdraw_keeper_workspace_presentation`(:10441~)은 상태 필드를 약 300줄에 걸쳐 하나씩 초기화. 새 기능이 상태 필드를 만들 때 여기에 추가하는 걸 컴파일러가 강제하지 못함. D-1의 패치가 계속 생기는 구조적 이유 (N-of-M).
- 수정: workspace에 묶인 상태를 레코드 하나로 모아 `state.scoped <- empty_scoped ()` 로 통째 교체.

**D-8 (P3) 문자열로 소속/종류 판정**
- `bin/masc_tui_lane_addons.ml:256`, `:613`: Lane 행이 어느 instance 소속인지 `String.starts_with ~prefix:(instance.id ^ "/") row.lane_id` 로 판정. id가 서로 접두어 관계면 먼저 걸린 것이 소유자가 됨.
- `bin/masc_tui_acting.ml:260~271`: `"keeper_skill"`, `"keeper_compose_"` 를 서버 카탈로그에서 복사한 리터럴(주석이 복사라고 인정). 서버가 바꾸면 TUI 표시만 조용히 틀어짐.
- `bin/masc_tui_observer.ml:496`: SSE event type을 `agent_core_prefix` 접두어로 분류.
- 수정: Lane 행에 `owner: instance_id` 필드를 서버가 주도록, tool 이름은 `lib` 상수 참조.

**D-9 (P3) 조용히 삼키는 곳과 가짜 값**
- `bin/masc_tui_http.ml:701`: `try Ok (member "frame" json |> to_int) with _ -> Ok 0` (MSX press 응답의 frame이 잘못돼도 0으로).
- `lib/tui_decode_memory_facts.ml` 병합 스냅샷의 `mos_revision = 1`, `mss_revision = 1` (실제 revision 아님).
- 확신 high, 영향 low.

**D-10 (P3) 고아 주석과 어긋난 들여쓰기**
- `masc_tui.ml:9914~9917`: "A read that fails leaves the last snapshot in place rather than blanking the pane" 주석이 `notify_new_asks` 앞에 붙어 있고, 바로 위 `apply_approvals_load`(:9906)는 오히려 스냅샷을 지움. 읽는 사람을 오도.
- `masc_tui.ml:27354~27355`: `| Lanes ->`, `| Clients ->` 가지 들여쓰기가 다른 가지와 어긋남 (충돌 해결 흔적).

## 5. 낭비

**W-1 tick 한 번에 요청 약 15개, 그중 /health 7개 (Overview/Approvals 화면 기준)**
- 계산 (코드): 신원 3 (`load_http_surfaces` 앞/범위 확인/뒤, masc_tui.ml:10323~10365) + briefing 1 + operator approvals 1 + asks 1 + roster 1 + turns 1 + schedules 1 + Gate 3 (프로브 2 + 읽기 1, masc_tui.ml:2689~2706) + held-call 3 (프로브 2 + 읽기 1, :2172~2178) = 15. 그중 `/health` 7개. 2초마다니 TUI 하나가 초당 7.5 요청.
- Gate와 held-call의 앞뒤 프로브는 읽는 동안 workspace가 안 바뀌었는지 보려는 것. 같은 보장을 "응답에 서버 신원/세대 헤더를 싣기"로 하면 프로브 4개가 0개로 줄어듦. 병행 TUI가 여럿(운영 중 20여개 PTY 테스트 포함)이면 서버 부하.
- 확신 medium-high. `Snapshot_read.Poll`이 이미 진행 중이면 건너뛰는 것은 일부 줄임.
- 라이브 증거: 7일 로그에 느린(1초 이상) 읽기가 `/keepers/turns` 9,529, `/keepers/tool-approvals` 5,889, `/keepers/composite` 5,032, `/health` 5,838, `/dashboard/scheduled-automation` 4,909, `/dashboard/gate` 1,655, `/keepers/asks` 3,124건 (중앙값 약 2초, 이 로그는 1초 넘은 것만 남기므로 선택 편향). tick 읽기가 서버 부하의 주요 소비자임을 확인.

**W-2 스케줄 목록을 모든 화면에서 2초마다**
- masc_tui.ml:3098 (`launch_schedules_load`), 주석에 "12.4 kB gzip, 서버 2.1ms" 라고 직접 적음. 용도는 일정 띠(agenda strip)의 "다음 wake" 한 줄. 목록(20행)을 매번 받아 디코드(전부 성공해야 함, D 목록 참고).
- 라이브: `/dashboard/scheduled-automation`은 느린 읽기 4,909건으로 요청 수 2위, 최대 27초.
- 수정: 서버가 `next_wake` 요약만 주는 작은 응답을 만들거나, 변경 감지(ETag는 이미 304를 쓰고 있음: 로그의 304 9,544건)에 맡기고 주기를 10초로.

**W-3 Memory 전체 보기 N+1**
- masc_tui.ml:4531~4551: 로스터 전체(이 머신 `.masc/keepers` 114개)를 Keeper마다 `/keepers/{k}/memory-facts` 직렬 호출. 진입 시 한 번이지만 114번 x (느린 날 1~10초). 한 fiber에서 순서대로.
- 수정: 서버에 fleet facts 엔드포인트, 또는 최소한 병렬 + 상한.

**W-4 Usage 화면: 천천히 변하는 데이터를 2초마다**
- `needs_account_emails`, `needs_provider_history`, `needs_runtime_quota`(`/runtime/resolved` 전체, 같은 응답을 디코더 두 번 통과: loader.ml:1290~1301)가 Metrics tick마다. 계정 이메일과 N일 history는 setup/일 단위로 바뀜.
- 수정: 화면 진입 + 수동 새로고침 + 60초.

**W-5 대시보드 증거 파일 13.8MB 커밋**
- `dashboard/evidence/*` 414파일, png 70개(최대 327KB), 중복 포함(`pr41206-integrated-browser/form-desktop.png`와 `pr41206-author-update-browser/form-desktop.png`는 같은 blob 7557af6c). 최근 하루 대시보드 변경 35.4k줄 중 24.1k줄(68%)이 증거 파일. git 이력이 계속 커지고, "얼마나 바뀌었나"를 볼 때 소음. 방지책: `.gitignore`에 evidence 출력 경로를 두고 PR 본문/아티팩트로.
- 확신 high(수치), 판단(필요성)은 운영자 몫. 변경 크기 지표(LoC)를 올리려고 증거를 넣은 것이라고 단정하지는 않음.

**W-6 Lane Add-ons 창이 열려 있으면 2초마다 `/lane-addons` 전체**
- masc_tui.ml:27300 근처. 편집/설치/메뉴 상태가 아니면 매 tick `Inspect` 또는 `Action_status`. 인벤토리 응답 크기는 확인 못 함 (미확인).

## 6. 용어·결합

- "Approvals" 하나가 서로 다른 4가지 목록을 합침: operator confirm queue(`/operator`), held call(`/keepers/tool-approvals`), Gate queue(`/dashboard/gate`), Ask(질문). 코드 이름도 제각각(`Operator_row`, `Keeper_tool_row`, `Gate_row`, `Home_held_call`, `Home_gate_request`). 용어집(`docs/spec/00-glossary.md`)에는 HITL, Approval Detail Pane, Ask만 있고 held call과 confirm queue 정의가 없음 (이름 검색 결과 `Home_held_call` 언급 한 곳뿐). 운영자는 "승인"이라고 부르는데 서버에서는 읽는 저장소가 3개. 제안: 용어집에 "held call = 도구 실행 직전 보류, Gate 행 = Auto Judge 대기열, confirm queue = 사람 확인 요청" 한 줄씩과 서로의 관계.
- "authority"가 뜻 4개: (1) TUI `workspace_authority`(정수 세대, 낡은 응답을 버리는 표), (2) `detail_read_authority`(unit ref), (3) Candle 쪽 `candle_authority_generation`/"Authority Withdrawal"(용어집 :1864, 잔액 관측 철회), (4) Completion Authority / Speaker Authority(판정 권한). 앞의 셋은 "이 응답이 아직 유효한가" 표인데 이름이 권한처럼 읽힘. state에 `*_generation`/`*_authority` 변경 필드가 32개. 제안: TUI 표는 `read_epoch` 한 종류로 합치고 이름에서 authority를 뺌.
- "Lane"이 뜻 둘: Keeper가 모델을 부르는 경로(Exact/Standalone lane)와 Lane Add-on(패키지 인스턴스). 코드에서 `row.lane_id`가 둘 다 담고 접두어로 소속을 구분(D-8). 제안: add-on 쪽은 `addon_instance` 로 부르고 id를 타입으로 분리.
- 결합: Candle 관측이 Keeper 로스터 응답 안에 들어 있음 (`decode_keeper_runtime_list`가 `(rows, errors, truncated, total, candle)`을 한 번에 반환, masc_tui.ml:10124~10140). 로스터가 실패하면 Candle도 Error로 바뀜. 서로 다른 도메인(Keeper 상태 vs 경제 장부)이 한 응답에 묶여 한쪽 실패가 다른 쪽 표시를 지움. 서버 쪽 분리가 필요한지는 미확인.
- 결합: TUI가 서버 타입을 일부 재사용(`Keeper_approval_queue_rules_types`의 summary)하고 일부는 다시 정의(`gate_pending_phase`가 서버 `approval_queue_phase`와 같은 4개 값). 재사용 범위가 일정하지 않음.
- "대시보드"라는 이름이 셋을 가리킴: 웹 앱(dashboard/), 서버 라우트 `/api/v1/dashboard/*`(TUI도 사용), TUI의 첫 화면 이름 "Dashboard/Home". 이 라우트 중 19개는 이 저장소 안에 호출하는 쪽이 없음 (7절).

## 7. 지울 것

대시보드 (dashboard/src)
- 도달 불가 파일 35개, 3,724줄 (E-work/scripts/reach.py 로 main.ts에서 정적 import를 따라가 계산). 테스트에서만 쓰는 것: `components/molecules/{trace,voice,feedback,artifact,broadcast,attach,streaming}-molecule.ts`, `memory/memory-lens.ts`, `memory-primitives.ts`, `common/agent-capability.ts`, `persistence-status.ts`. 아무도 안 쓰는 것: `styles/tokens.generated.ts`(531줄), `demo/*` 픽스처 10여개. 동적 import나 외부 도구(vite 별도 엔트리, e2e)에서 쓰는지 확인 못 한 것은 제외하고 지워야 함. 확신 medium-high.
- 같은 모양 3개: `lib/{exact,browser,machine}-lane-observation.ts`(각 16~17줄, 이름만 다름). 하나의 `createObservationSignal()`.
- `*ForTesting` 내보내기 8곳(test backdoor, 워크어라운드 체크리스트 6번). 테스트가 상태를 직접 못 비우면 구조를 고쳐야 함.
- evidence 13.8MB (W-5).

서버 라우트 중 이 저장소에 호출자가 없는 것 (fb5344a25a, dashboard/src + bin 검색, 외부 curl/키퍼 도구 사용은 확인 못 함)
- `/api/v1/dashboard/` 아래: `keeper-practice`(#41292가 387줄 서버 코드 + 430줄 테스트를 "feat(dashboard)"로 추가했으나 대시보드/TUI에 화면 없음. #41403이 schema v2로 또 고침), `eval-feed`, `goals/measurements`, `goals/delete`, `keeper-decisions-log`, `board/close`, `board/reopen`, `gate/keeper-mode`, `provider-logs/tail`, `runtime/keeper-exact-lane`, `browser-lane/goto`, `browser-lane/session`, `tasks/assign-goal`(문서는 "HTTP route"라 하지만 호출자 없음), `agent_core/telemetry/{recent,summary}`. 합계 15개. 소비자가 없으면 지우고, 있으면 소비자를 같은 PR에 넣는 규칙이 필요.

TUI
- `Approval_stale` 중 Gate 쪽 경로는 도달 불가 (D-2). 정책을 "유지"로 바꾸면 살아나고, 계속 "비움"이면 지움.
- `masc_tui_acting.ml:260~271` 서버 상수 복사본 (D-8).
- 오래 남은 고아 주석 (D-10).
- (확인 못 함) TUI 상태 `mutable` 필드 675개 중 쓰기만 있고 읽기 없는 것. #41471, #41468이 죽은 함수를 지운 것을 보면 더 있을 가능성이 높음. `bin/dune`에 unused 경고가 꺼져 있는지 확인이 먼저.

## 8. 확인하지 못한 것 (솔직하게)
- Task 목록, Verification 큐, Candle/Items/Portrait 의 디코더 세부, Lane Add-ons 인벤토리 응답 크기, Board 쓰기 경로.
- 대시보드 SSE 갱신과 폴링 비용. 서버 쪽 `/api/v1/dashboard/*` 응답 크기.
- 모든 라이브 수치는 PTY 테스트가 만든 로그를 포함. 실사용 TUI 요청 비율은 분리하지 못함.
- 진행 중 PR(#41499~#41524)은 보지 않음. D-1/D-2를 건드릴 가능성이 있는 것은 신원/Gate 관련 PR뿐인데 제목만으로는 판단 불가.
