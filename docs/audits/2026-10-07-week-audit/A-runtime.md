# A-runtime 감사: Keeper turn 과 runtime cycle

기준: origin/main fb5344a25a (2026-10-07 14:03 KST). 코드는 `src-A` 스냅샷(같은 커밋)으로 읽었다.
실데이터: `~/me/.masc/logs/system_log_2026-10-0{5,6,7}.jsonl`, `~/me/.masc/costs/2026-10/*.jsonl`. 모두 읽기만 했다.
수치는 UTC 날짜 기준 10-06 하루치다. 따로 적지 않으면 그 날 값이다.

## 1. 영역 지도

Turn 한 번의 흐름은 이렇다.

1. `keeper_turn.ml`(57KB)이 입력을 받는다. direct 입력이면 `Keeper_repetition_scope.Execution.direct_operation` 으로 operation 하나가 repetition 상태를 쥔다 (keeper_turn.ml:465).
2. `keeper_agent_run.ml`(124KB)이 turn 을 만든다. 도구 표면(`keeper_run_tools_setup.ml` → `prepare_agent_setup`), 반복 감지 seed, 사전 정산(`Keeper_unsettled_spend.settle_before_execution`, :1126)을 한다.
3. `keeper_turn_driver.ml`(143KB, `run_named`)이 lane 의 candidate 를 순서대로 걷는다 (`attempt_runtime_candidates`, :757 부근).
4. `keeper_turn_driver_try_provider.ml`(143KB)이 candidate 하나에 요청을 보낸다. carried range(보낼 이력 구간)를 고르고, 거절당하면 앞부분을 줄이거나 다음 candidate 로 넘긴다.
5. 공식 클라이언트 lane(Claude Code, Codex, Antigravity, Muse)은 `keeper_official_client_host.ml`(96KB)이 맡는다. 반복 감지는 도구 호출이 끝날 때마다 `official_client_tool_boundary` 로 부른다.
6. AGENT_CORE lane(ollama_cloud, glm-coding, kimi)은 step 마다 checkpoint 를 세 번 쓴다 (`checkpoint_sink`, keeper_agent_run.ml:1620 부근 → `Keeper_checkpoint_store.save_agent_core_classified_typed`, :1572).

저장소와 소비자는 다음과 같다.

- checkpoint 정본: 세션 디렉터리의 canonical 파일. 옆에 지난 stage 저장본을 hardlink 로 `keeper.checkpoint_history_retained`(기본 3, runtime_settings.ml:281)개 남긴다.
- 도구 호출 ledger: `Keeper_tool_call_log` → SQLite 색인(`keeper_tool_call_index`). 반복 감지 seed 와 TUI 가 읽는다.
- 비용 ledger: `~/me/.masc/costs/YYYY-MM/DD.jsonl`. raw 행(요청 단위)과 resolved 행이 섞여 있다.
- Librarian 위치(`librarian-progress.json`, `turn-boundaries.jsonl`): carried range 의 시작 지점. memory 영역(audit-memory) 소관이라 여기서는 소비 쪽만 본다.
- runtime 설정: `runtime.toml`(`Runtime_toml` 135KB, `Runtime` 175KB). lane 은 `[runtime.lanes.*]`, 키퍼 배정은 같은 파일의 배정표.

실패 시 다음 시도를 정하는 모듈은 `keeper_runtime_failure_route.ml` 의 `path_rest_sec` 와 `keeper_turn_driver.ml:421-510` 의 `next_dispatch_after_failure` 다.

## 2. 7일 흐름 (lib/runtime + lib/keeper)

창별 커밋 수(두 경로 합계, 병합 제외): D-7 20, D-6 47, D-5 35(병합 포함 45), D-4 10, D-3 29, D-2 1, D-1 48.

**D-7 (09-29).** runtime 쪽은 provider 계정이 model set 을 공유하게 했다 (#40096). Codex 가 GPT-6.1 Sol 과 ultra effort 를 받았다 (#40090). 성능 3건(#40084, #40085, #40087)은 도구 이름과 skill 목록을 매번 다시 계산하지 않게 했다. keeper 쪽은 "native resume 때 같은 context 를 반복 전송"(#39972)과 Librarian 끝 줄 없는 atom 읽기(#40019)를 고쳤다. CI 의 임의 숫자 검사(#40267, #40265)는 지웠다.

**D-6 (09-30).** 이 영역에서 가장 시끄러운 날이다. context window 를 provider 와 runtime 단위로 좁혔다 (#40493, #40554). "저장된 지식을 전부 주입하지 않고 필요할 때 검색"(#40473)이 들어왔다. 관측 callback 을 attempt 에 묶는 수정이 4건 연달아(#40524, #40530, #40537, #40544) 들어갔다. Codex 쪽은 timeout 증거 보존(#40500), 계정 한도 때문에 lane 전체를 세우지 않는 수정(#40503), exact-lane 후보가 요청 전 네트워크 실패하면 격리하지 않고 기다리는 수정(#40397)이 있다. 승인 큐 리팩터 5건(#40112 ~ #40235)은 구조만 옮겼다.

**D-5 (10-01).** recall 을 "검색 우선, 대량 fallback 없음"으로 바꿨다 (#40782, #40784, #40826). 사흘 전 도입한 recall 주입 방식을 이틀 만에 다시 바꾼 셈이다. 스트리밍 출력 보존(#40736, #40750)과 exact-lane backpressure 귀속을 rebind 에도 고정하는 수정(#40742)이 있다. Codex effort 병합 커밋이 약 20개 섞여 있어 `git log` 가 읽기 어렵다.

**D-4 (10-02).** Execute 결과 게시를 CPU pool 로 옮겼다 (#40808, #40880). exact lane candidate 를 한 번에 바꾸고 첫 번째로 올리는 기능(#40723)과 모르는 model capability 키 거절(#40926)이 들어왔다.

**D-3 (10-03).** 알 수 없는 provider 필드를 거절(#41048)하고, 큐 표시에서 live 실행, 대기 입력, 예약을 구분했다 (#41051). 메트릭 보존 정책 3건과 setup wizard 수정이 많다. Librarian JEV 변경 판정 사전 검사는 선택 기능으로 들어왔다 (#40758).

**D-2 (10-04).** 이 영역 커밋은 TUI 기본 경로 편집기 수정 1건뿐이다.

**D-1 (10-05 ~ HEAD).** 다섯 갈래다.

- 반복 감지: 호출 ledger 에서 cross-cycle seed(#41234), 도구의 "답"만 비교(#41398).
- byte 상한 제거: `max-prompt-bytes` 삭제(#41224 병합, 18b85e62df), keeper 브리핑을 byte 예산 없이 통째 전송(#41351).
- 끊긴 실행 정산: 정산 신설(#41383), 관측값을 그대로 읽게 변경(#41387), 못 읽는 줄을 사유와 함께 알림(#41400).
- 계정 admission: 허용량이 바뀌는 설정 변경 거절(#41359), judgment lane 이 풀린 permit 을 Keeper turn 보다 먼저 가져감(#41332).
- Muse·Ollama 사용률: Muse 사용률 기록과 소진 처리 통합(#41360, #41362), Ollama Cloud 잔여 한도를 `/api/balance` 에서 읽기(#41476).

**Churn 메모(되돌림과 덧댐 신호).**

- 같은 문제를 여러 번 다룬 예: 반복 감지가 D-1 하루 안에 두 번 바뀌었다(#41234 seed, #41377/#41398 답만 비교). 아래 P2-1 결함이 이 사이에서 생겼다.
- checkpoint 요약 재읽기를 10-06 에 고쳤다 (#41406, "링크 세션 루트에서 다시 읽지 않게"). 그 전에는 stage 저장마다 30MB 를 다시 읽었을 수 있다. 근거는 `known_watermark` 의 `cached_summary` 가 실제 경로가 아닌 키로 찾았다는 커밋 제목뿐이라 confidence 는 medium 이다.
- recall 주입은 D-6(#40473)과 D-5(#40782)에 두 번 방향이 바뀌었다.
- 승인 큐, observer 귀속은 구조 리팩터와 수정이 번갈아 들어왔다. 기능 변화는 없었다.

## 3. 기능 매트릭스

열 순서: 기능 | 정상 경로 | 경계·코너 | N-Tick 순환 | 관측성 | TUI 연결 | 테스트 | 판정 | 근거 | 제안 | 크기.
"TUI 연결"은 이 감사에서 TUI 쪽 코드를 읽지 않았으므로 로그와 호출 이름으로만 적었다. 읽지 않은 곳은 "미확인"이다.

| # | 기능 | 정상 경로 | 경계·코너 | N-Tick 순환 | 관측성 | TUI | 테스트 | 판정 | 근거 | 제안 | 크기 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Runtime failover (candidate 걷기, deferred suffix, 정렬) | lane 후보를 선언 순서로 걷고, 쿼터·backpressure 로 쉬는 후보는 뒤로 민다. 실패하면 남은 후보를 `deferred_runtime_lane` 으로 넘겨 다음 turn 이 이어 걷는다 | lane 이 후보 하나 남으면 매번 같은 후보만 두드린다. 계정 한도 문구가 `Rate_limited` 로 분류되면 휴식이 60초에 머문다 (P2-2) | 닫힘 조건은 "휴식이 풀림"뿐이다. 한도가 안 풀리면 60초 주기로 무한 재시도한다. 10-05 19:57Z ~ 10-06 01:59Z 6시간 동안 3 keeper 가 약 350회 실패 | `keeper cycle FAILED`, `next dispatch waits Ns` 로그가 있다. 후보별 실패 사유는 attempts 목록에 남는다 | 미확인 | 있음(`test_keeper_*` 다수, 개별로 읽지 않음) | 의심 | keeper_turn_driver.ml:421-510, keeper_runtime_failure_route.ml:424-440 | #41476 이 Ollama 잔여 한도를 읽게 했다. 실제 wire 로 `Hard_quota` 가 되는지 확인하는 테스트를 추가한다 | M |
| 2 | 계정 admission, 동시성 한도 | provider 계정의 permit 에 judgment lane(verifier, HITL, board attention)이 Standard 요청보다 먼저 선다. 설정이 허용량을 바꾸면 거절한다 | 큐 구현이 이 저장소 밖(agent core)에 있어 이 감사에서 못 읽었다. 같은 계정을 쓰는 Keeper turn, Librarian exact lane, curator 가 한도 상태를 서로 알려 주는지 확인하지 못했다 | 10-06 에 Librarian exact lane 이 같은 소진 계정에 945회 실패했다 (01:08Z ~ 11:11Z) | 거절 로그는 있다. permit 대기 시간 지표는 확인하지 못했다 | 미확인 | #41332, #41359 에 테스트가 있다고 커밋 본문에 적혀 있다 (읽지 않음) | 미확인 | git show db17589b34, 9ec51ca0ce | 큐 구현을 읽은 뒤 판정한다 | - |
| 3 | turn 이 window 를 넘지 않음: provider 의 typed 거절로 반응, byte 상한 없음 | 요청 전에 byte 를 재지 않고, `ContextOverflow` 와 body 거절이 오면 carried range 앞을 줄여 같은 후보에 다시 보낸다 | 이유를 모르는 400(`Unknown_invalid_request`)은 turn 경계에서 한 번 더 보낸다. 요청 하나가 더 청구된다 | 닫힘. 줄이는 순서가 단조(앞부분이 strictly 줄어듦)이고 한 atom 에서 멈춘다 | `model input carried range ...` 로그에 atoms, transmitted_bytes, reserved_bytes 가 나온다 | 컨텍스트 게이지(#41423) | 있음(`test_keeper_claude_code_runtime.ml:3127` 등) | 정상(코드 경로). 이유 모르는 400 은 비용이 있음 | keeper_turn_driver_try_provider.ml:2385, 2482, 2288 | prose-only 400 에 typed 이유를 파서 경계에서 붙이면 `Unknown_invalid_request` 재전송이 사라진다 | M |
| 4 | 한 Keeper 의 context 수명: turn 시작, step, checkpoint, turn 경계, 재개 | step 마다 checkpoint 를 3번(assistant 수집 후, 도구 결과 후, context 주입 후) 정본에 통째로 쓴다. 요청은 Librarian 이 읽은 위치부터의 carried range 만 보낸다 | 정본은 transcript 전체다. 줄이는 경로는 대시보드의 수동 purge 뿐이다 | 열림. 정본이 step 당 약 3.5 ~ 13KB 씩 선형 증가하고 저장은 매번 전체다 (P1-1, P1-2) | `checkpoint_save ... duration_ms canonical_bytes` 로그 | 대시보드 checkpoints API | 있음(store 테스트 다수) | 결함 | 10-06 로그 집계. keeper_agent_run.ml:1620-1690, keeper_checkpoint_store.ml:1572-1660 | stage 저장을 줄이거나 append-only 로 바꾼다. 자동 purge 나 분할이 필요하다 | L |
| 5 | 끊긴 turn 재개와 사용량 정산 | 이어받는 실행이 시작되기 전에 직전 raw 비용 행을 resolved 로 정산한다. Codex handoff 뒤 미완료 direct 작업을 이어간다 | 해당 Keeper 의 resolved 행이 하나도 없으면 비용 ledger 를 오래 거슬러 올라가며 읽는다 | 닫힘. resolved 행이 생기면 거기서 멈춘다 | 정산 건수와 못 읽은 줄 사유를 로그로 남긴다 (#41400) | 미확인 | 있음(`keeper_unsettled_spend` 테스트는 읽지 않음) | 정상(코드 읽기 범위) | keeper_unsettled_spend.ml:196-273 | 둠. 새 Keeper 첫 실행 비용만 한 번 확인한다 | S |
| 6 | 반복·루프 감지 (exact 축, input 축, text 축, ledger seed) | 같은 도구+입력+출력 지문이 3번이면(비인접 포함), 같은 도구+입력이 연속 5번이면, 같은 assistant 텍스트가 연속 3번이면 yield | ledger seed 가 오래된 순으로 들어가고, `seed_beyond` 가 개수로 자른다 (P2-1) | ledger 구간이 200행에 차고 한 번 yield 하면 seed 가 영구히 비게 된다(코드 추론, 실측 없음) | yield 사유가 `stop=yielded_after_repeated_tool_call(...)` 로 기록된다. 10-06 약 58건 | 미확인 | 있음. 단 순서 버그를 오히려 고정하는 단언이 있다 (`test_keeper_turn_outcome.ml:1154`) | 결함 | keeper_run_tools_setup.ml:345-400, 651; keeper_repetition_judged.ml:64; keeper_tool_call_index.ml:416-446 | seed 를 `List.rev` 하고, `judged` 를 개수 대신 tool_use_id 나 행 id 로 바꾼다 | S |
| 7 | operation 큐와 drain | 큐가 비어 있지 않으면 cooperative yield 로 turn 을 넘기고, 소비자는 queued observation 을 turn 입구로 올린다 | board attention drain 의 약 절반이 판정 0건이다 | 닫힘(관측 범위). drain 이 judgments=0 으로 끝난다 | `board_attention_worker_drain ... judgments=N` 1773건 중 864건이 0건 | `masc_tui_queue_inspection` 이 live 실행, 대기 입력, 예약을 구분 (#41051) | 있음 | 의심(낭비 수준) | 로그 집계. 코드는 `Runtime_agent.Yielded_to_operation_queued` 주변만 봄 | 0건 drain 이 lane permit 이나 요청을 쓰는지 확인한다. 쓰지 않으면 둠 | S |
| 8 | turn 마다 주입되는 context(도구 스키마, 결과, recall, system prompt) | Claude Code lane: 도구 155개, 스키마 약 152 ~ 155KB, system prompt 약 20 ~ 26KB. AGENT_CORE lane: 도구+system 고정 약 93KB(reserved_bytes) | recall 은 "검색 우선"으로 바뀌어 기본 주입이 줄었다. completion-review verifier 세션이 첫 prompt 로 1.3 ~ 1.5MB 를 보낸 날이 있다 | 열림(step 당 반복). 같은 93KB 가 turn 의 모든 step 에서 재전송된다. cache 적중이 96 ~ 99% 라 청구는 작다 | `Claude Code turn composition: ... tool_surface_bytes` 로그 | 컨텍스트 게이지 | 비교 테스트 없음(확인 못 함) | 의심(낭비) | 로그 집계, 비용 ledger | 낭비 절 참고 | M |
| 9 | 최종 정리: 사용량 지표와 cost ledger | 요청마다 raw 행, turn 확정 때 resolved 행. 10-06 raw per_request 17,415, resolved 약 16.5k | `cost_usd` 가 전부 0이고 `cost_status: agent_core_cost_unreported` 라 금액 지표로는 못 쓴다 | 닫힘 | 위 파일 | 미확인 | 미확인 | 미확인 | costs/2026-10/06.jsonl | economy 영역에서 본다 | - |

판정 집계: 정상 2 (3, 5), 의심 3 (1, 7, 8), 결함 2 (4, 6), 미확인 2 (2, 9).

## 4. 결함 목록

### P1-1. step 마다 checkpoint 정본을 통째로 3번 쓴다 (하루 약 2TB)

- 위치: keeper_agent_run.ml:1620-1690 (`checkpoint_sink`), keeper_checkpoint_store.ml:1572-1660, keeper_fs.ml:504-593 (payload fsync 와 부모 디렉터리 fsync 를 한다).
- 사건: AGENT_CORE lane 한 step 이 `after_assistant_collected`, `after_tool_results_appended`, `after_context_injection` 세 stage 에서 같은 정본 파일을 처음부터 다시 쓴다. encoding memo 는 인코딩 CPU 만 줄인다. 파일 쓰기 크기는 줄지 않는다.
- 실측(10-06 로그 `checkpoint_save`): 저장 약 52,000회, canonical_bytes 합계 약 1,964GB. p50 31.7MB, p90 82MB, 최대 92.3MB. 저장 시간 합계는 약 45분이다. 많이 쓴 Keeper 는 indie-geek-blue 324GB, code-reviewer 282GB, jazz-developer 263GB 다.
- 영향: 이 장비의 SSD 는 4TB 인데 하루 약 2TB 가 쓰인다. 쓰기 증폭과 수명이 직접적인 비용이다. 저장 한 번이 66ms 안팎이라 turn 지연은 크지 않다.
- 확신도: high (로그 수치와 코드 일치). SSD 수명 영향은 확인하지 못했다.
- 최소 수정: 정본에 쓰는 stage 를 resume 에 필요한 하나로 줄인다. 일단 `after_context_injection` 이 `after_tool_results_appended` 와 다른 정보를 담는지 확인하고, 같다면 지운다. 그 다음 append-only journal 로 간다. 새 추상화는 필요 없다.

### P1-2. checkpoint 정본이 step 마다 커지고 자동으로 줄어들지 않는다

- 위치: keeper_checkpoint_purge.ml 의 호출처는 `server_dashboard_http_keeper_api_checkpoints.ml:450` 한 곳(수동 API)뿐이다 (`rg Keeper_checkpoint_purge.` 결과).
- 실측: 10-05 ~ 10-06 사이 indie-geek-blue 16.6MB → 51.6MB (turn_count 2241 → 8163, step 당 약 5.9KB). you-never-change 0.4MB → 28.4MB. jazz-developer 와 polisher 는 이미 77 ~ 86MB.
- 영향: P1-1 의 쓰기량이 이 크기에 비례한다. 설정 설명에 라이브 Keeper 하나가 "111MB" 라고 적혀 있다 (runtime_settings.ml:281 부근).
- 확신도: high. 요청 쪽은 carried range 로 잘리므로 모델에 보내는 양은 별개다.
- 최소 수정: purge 를 자동 트리거로 부른다. Librarian 이 읽은 위치 앞에서 잘라 Unread_atoms_present 거절을 피한다.

### P2-1. ledger 로 심는 반복 감지 seed 의 순서가 거꾸로이고, 포화되면 꺼진다

- 위치: keeper_run_tools_setup.ml:345-400 (`seed_tool_calls_from_ledger`), :651 (`history_pairs @ ledger_pairs`), keeper_repetition_judged.ml:64 (`seed_beyond`), keeper_tool_call_index.ml:416-446, test_keeper_turn_outcome.ml:1154.
- 사실 1: 색인은 최신순으로 뽑고 누적하면서 뒤집어 "오래된 것부터" 돌려준다 (keeper_tool_call_index.ml:441 부근 주석). `seed_tool_calls_from_ledger` 는 그대로 돌려준다. 탐지기는 "최신순, 머리가 latest" 를 가정한다 (`repeated_tool_call_input` 의 streak, `seed_tool_calls_from_history` 의 주석). 따라서 ledger 구간에서는 첫 live 호출이 가장 오래된 행과 비교된다.
- 사실 2: 테스트가 이를 고정한다. 행을 u1, u2, none 순으로 쓰고 `seeded` 의 머리가 u2 인지 확인하면서 "newest" 라고 적었다. 실제 최신은 none 이다.
- 사실 3: `seed_beyond ~judged` 는 목록 뒤에서 `judged` 개를 자른다. 최신순이면 오래된 것이 잘린다. ledger 구간에서는 최신 것이 잘린다.
- 사실 4(코드 추론): ledger 는 최근 200행으로 막혀 있다 (`ledger_seed_row_limit`). yield 가 `history_pairs_at_setup + live` 를 기록하고 `restore` 가 max 를 취하므로, 구간이 200에 찬 뒤 한 번 yield 하면 `judged >= 200` 이 되고 이후 `keep = max 0 (total - judged)` 가 0이 된다. 그 Keeper 는 cross-cycle 감지가 영구히 꺼진다. 실측하지 않았다.
- 영향: #41234 의 목적(cycle 사이 반복 감지)이 input 축에서는 어긋나고, 포화 시 exact 축도 꺼질 수 있다. exact 축은 순서에 영향을 받지 않아 첫 yield 전까지는 동작한다.
- 확신도: 순서는 high, 포화는 medium.
- 최소 수정: `seed_tool_calls_from_ledger` 끝에 `List.rev` 를 넣고 테스트 기대값을 고친다. `judged` 는 개수 대신 마지막으로 판정한 tool_use_id(또는 행 id)로 바꾼다. "개수는 append-only 일 때만 안정" 이라는 전제를 타입으로 바꾸는 방향이다.

### P2-2. 계정 단위 한도가 `Rate_limited`(60초)로 분류되어 6시간 동안 재시도했다

- 위치: keeper_runtime_failure_route.ml:424-440 (`path_rest_sec`: `Hard_quota` 는 cap 900초, 나머지는 floor 60초), keeper_turn_driver.ml:454-510.
- 실측: 10-05 19:57Z ~ 10-06 01:59Z. 응답은 `429 ... you have reached your session usage limit, add usage credits (retry_after: none)`. 실패 간격이 p50 64초다. indie-geek-blue 134회, you-never-change 116회, sangsu 97회, code-reviewer 32회가 `Rate limited` 로 끝났다. 실패한 cycle 의 지연이 합쳐 indie-geek-blue 246분, sangsu 491분이다. 같은 계정의 Librarian exact lane 도 10-06 01:08Z ~ 11:11Z 에 945회 실패했다 (같은 문구의 429).
- 원인: Ollama 의 429 가 typed `HardQuota` 로 오지 않고 `RateLimited` 로 온다. 문구를 읽어 분류하면 string 분류기가 되므로 코드는 하지 않았다. 대신 쿼터 창(`Runtime_quota_window`)이 잔여 한도 읽기로 소진을 표시해야 하는데, 그 읽기(`/api/balance`)가 10-07 11:59 KST 에야 들어왔다 (#41476).
- 현재 상태: 10-07 04Z(13:00 KST)에 `Rate limited` 로 끝난 cycle 이 130건 더 있었다. 서버가 13:54 KST 에 다시 떴고 그 뒤 실패는 없다. 수정이 배포된 바이너리에서 작동하는지는 확인하지 못했다.
- 확신도: 사건은 high. 수정 효과는 medium(미검증).
- 최소 수정: 실제 Ollama 응답 본문으로 `Runtime_quota_window` 가 소진 상태가 되는지 확인하는 테스트를 붙인다. 소진이면 같은 계정의 Keeper turn, Librarian, curator 가 한 상태를 같이 본다.

### P3-1. 반복 감지 임계값 3, 3, 5 와 `ledger_seed_row_limit` 200 의 근거가 부분적이다

- 위치: keeper_agent_run.ml:194, 207, 287; keeper_run_tools_setup.ml:330; keeper_turn_driver_try_provider.ml:2288 (`context_overflow_shrink_divisor = 2`).
- 입력 축 5는 2026-09-01 ~ 03 의 3일 데이터에서 골랐고 주석이 "남은 호출에 대해서는 측정하지 않았다 (#36503)"고 적는다. 200 행은 근거를 적지 않았다. 반으로 줄이는 2는 "provider 가 판정하므로 변환 상수가 필요 없다"고 설명한다. 이 둘은 문서화된 예외라 P3 로 둔다.

### P3-2. 이유를 모르는 400 마다 요청이 한 번 더 나간다

- 위치: keeper_turn_driver_try_provider.ml:2482-2490 (`boundary_resend_on` 이 `Unknown_invalid_request` 를 받아들임). 주석이 비용을 직접 적었다("one more request for each 400 whose reason is unknown").
- 근본: prose 로만 오는 크기 거절의 typed 이유를 파서 경계에서 붙인다. 문구를 읽는 대신 provider 별 응답 모양을 한 번만 해석한다.

### P3-3. workspace curator 가 같은 설정 오류로 반복 실패한다

- 위치: server_workspace_memory_curator.ml:158. 10-06 07:55Z ~ 15:08Z 에 `workspace curator cannot bound official-client slots without a declared context window` ERROR 273회(약 95초 간격).
- 설정에 CLI slot 이 들어 있으면 curator 는 결정적으로 실패하고, 호출자는 계속 다시 부른다. 닫히지 않는 순환이다. 메모리에 "curator 는 10-07 부터 GLM 으로 운영 중" 이라고 적혀 있어 이후 조치된 것으로 보이나 이 감사에서 확인하지 않았다.
- 제안: 결정적 설정 오류는 같은 설정 세대에서 한 번만 시도한다.

### P3-4. lane 인벤토리가 읽을 때마다 같은 경고를 낸다

- 위치: lane_addon_runtime.ml:819, 1062. 10-06 에 `Lane retained binding omitted from inventory` 가 1065건 (`ambiguous retained producer`)과 180건 (`invalid released binding shape`).
- 이 영역 밖(lane add-on)이라 증상만 적는다. 경고가 읽기 호출 단위라 같은 binding 이 반복 기록된다.

### P3-5. 작은 정리

- `Keeper_tool_progress_identity.For_testing` 이 비어 있다 (keeper_tool_progress_identity.ml:324).
- `history_memos` 표(:288)에서 삭제된 Keeper 의 항목을 지우는 곳이 없다. `History_memo` 는 한 keeper 의 지난 walk 의 모든 쌍을 쥔다 (실측 한 keeper 에 출력 30.2MB, 코드 주석 2026-09-15).
- `docs/evidence/` 에 6,600개 파일이 있고, 빈 컴파일러 로그(`*.cmi.log`, `*.cmo.log`) 8개가 #41051 커밋으로 들어와 있다.

## 5. 낭비

수치는 10-06 하루치 로그와 비용 ledger 에서 센 것이다.

1. **checkpoint 전체 재기록 (P1-1).** 약 1.96TB/일, 저장 시간 약 45분/일. step 마다 3번. 수정은 stage 를 줄이거나 journal 로 바꾸는 것이다.
2. **AGENT_CORE lane 의 step 반복 재전송.** 요청 17,415건, 입력 토큰 합계 약 20.5억, cache 읽기 약 19.7억 (96%). 도구 스키마와 system prompt 를 합친 reserved_bytes 중앙값이 약 93KB 라서, step 마다 같은 93KB 가 다시 나간다. cache 적중이라 청구액은 작다. 다만 provider 쪽 "세션 사용량 한도"에 cached 토큰이 포함되는지 확인하지 못했다. 포함된다면 P2-2 의 한도 소진과 연결될 수 있다.
3. **Claude Code lane 의 도구 표면.** 1,397 turn, 도구 155개, 스키마 약 152 ~ 155KB (약 38K 토큰)가 turn 마다 구성된다. 이 크기는 거의 일정(155개, 5개 Keeper 조합에서 같은 값)해서 키퍼별로 도구를 고르는 설정이 거의 쓰이지 않는 것으로 보인다. 설정 사용 여부는 확인하지 못했다(low).
4. **verifier 세션의 큰 첫 prompt.** `completion-review-*` 세션 첫 prompt 가 10-05 에 150건, 합계 27.4MB, 최대 1.52MB 였다 (10-06 은 5건). Claude Code `start` 모드 전체로는 10-06 에 203건, 합계 27MB.
5. **같은 소진 계정에 반복되는 요청 (P2-2).** keeper cycle 약 350건, Librarian 945건, 6시간. cycle 한 건의 지연이 평균 약 110초다.
6. **정산 스캔.** `settle_before_execution` 이 turn 마다 비용 ledger 를 최신순으로 훑는다. 정상 Keeper 는 몇백 행이면 멈춘다. 비용: 하루 약 2천 실행. 현재로는 작다.
7. **Codex 계정 홈.** `~/me/.masc/official-clients/codex/324a...` 한 곳에 `state_5.sqlite` 13.5GB, `logs_2.sqlite` 6.2GB, `thread_history_1.sqlite` 4.9GB, sessions 11GB, 합계 약 35GB. 보존 정책이 MASC 쪽에 있는지 확인하지 못했다. 전체 `official-clients` 는 약 60GB.

## 6. 용어와 결합

용어집(`docs/spec/00-glossary.md`, 3,390줄)과 코드를 맞춰 본 결과다.

- **carried range (보낼 이력 구간).** 코드 28곳, 로그 문구 `model input carried range` 로 쓴다. 용어집에 항목이 없다. 대신 "Carried Front(실어 보낼 이력의 시작 위치)" 항목이 있다 (용어집 :2777). 코드는 `carried_front` 244곳, `carried_range` 28곳이다. 같은 대상의 시작 위치(front)와 구간(range)을 둘 다 쓰므로, "range 의 앞쪽 경계가 front" 라는 한 줄을 용어집에 적는다.
- **librarian point, position, accepted start, boundary, seed.** 한 turn 안에서 "Librarian point", "turn boundary", "accepted start", "seed" 가 모두 구간의 시작 후보다. `seed` 는 이 영역에서 최소 네 가지 뜻이다. carried front 의 씨앗, checkpoint 에서 심는 반복 감지 seed, ledger 에서 심는 seed, `Runtime_inference.for_runtime ~name` 의 `runtime_seed`. 반복 감지 쪽은 "시드" 대신 "초기 이력"처럼 구체적인 이름이 낫다.
- **lane.** 용어집은 "Lane(고정 실행 경로)"와 "Standalone Lane", 그리고 lane add-on(browser, msx, dos) 인벤토리를 다룬다 (용어집 :1057-1099). 코드는 `runtime lane`(`runtime_lane=runtime` 로그), `exact lane`, `deferred runtime lane`, `official-client lane`, `AGENT_CORE lane` 을 같은 글자로 쓴다. 이 중 `runtime lane` 은 용어집에 정의가 없다 (grep 0건).
- **cycle, turn, step, round.** 로그에는 `keeper cycle`, `turn`, `max_tool_rounds` 가 섞여 나온다. 용어집은 Turn 만 정의한다 (:573). `turn_count` 는 Keeper turn 이 아니라 step(assistant 응답 1회) 수다. 같은 로그 줄에 `turn=5780 total_turns=1589`(step 번호와 Keeper turn 수)가 함께 나온다. 같은 이름의 두 뜻이다.
- **checkpoint.** AGENT_CORE 정본(canonical), history 스냅샷(`checkpoint_history_retained`), 공식 클라이언트의 세션, 반복 감지의 `repetition_checkpoint` 이름표, `Keeper_replay_checkpoint` 가 모두 checkpoint 다. history 스냅샷은 실제로는 "지난 stage 저장본"이라서 turn 단위 과거를 보여 주지 않는다 (확신도 medium. hardlink 와 created_at 이름 규칙만 읽었다).
- **분리 제안.** `keeper_turn_driver_try_provider.ml` 은 143KB, 3,149줄 한 파일 안에 continuity 선택, carried range 조립, eviction 정책 4종, truncation 복구, stall 감시가 들어 있다. 이 안에서 "eviction 정책"(2288 ~ 2740)은 인자로 `attempt` 를 주입받는 순수 함수라 따로 떼어도 잃는 것이 없다. 분리는 RFC-0051 PR-3a 가 이미 한 번 했고 이 파일이 그 결과물이다. 더 쪼갤 때는 블록 경계로 하라는 저장소 지침을 따른다.

## 7. 지울 것

1. `Keeper_tool_progress_identity.For_testing` (빈 모듈, :324).
2. `docs/evidence/queue-inventory-observation-20261004/*.cmi.log, *.cmo.log` (크기 0 파일 8개). 같은 디렉터리의 다른 증거 파일도 `docs/evidence` 6,600개 중 몇 개가 실제로 참조되는지 점검한다.
3. P1-1 수정과 함께 `after_context_injection` stage 저장(같은 정보면).
4. `context_overflow_shrink_sequence`(옵션 인자 3개, 주입 콜백 2개)와 `carried_range_eviction_sequence`, `halve_front` 는 같은 일을 하는 두 경로(공식 클라이언트 lane 은 capacity 반감, AGENT_CORE lane 은 range 앞 이동)다. 코드 안 주석이 둘의 차이를 길게 설명한다. 둘이 같은 `refusal_evicts` 로 합쳐질 수 있는지 확인한다 (확인하지 못함, low).
5. `history_memos`(삭제된 Keeper 항목이 남음).
