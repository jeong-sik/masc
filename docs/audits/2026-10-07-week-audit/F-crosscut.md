# F-crosscut: 7일 전체 diff 횡단 품질 + 라이브 설정

범위: `e126a20e72..fb5344a25a` (1,347 커밋, lib+bin 1,105 파일 +76,769/-36,591, test 1,047 파일 +113,250/-63,953, docs 3,062 파일 +182,590). 읽기 전용. 코드 근거는 `fb5344a25a:<경로>:<줄>`.
증거 파일(감사 세션 임시 폴더, 저장소에 없음): (net_added.txt = 추가된 줄에서 같은 내용이 삭제된 줄을 뺀 목록 52,187줄, nl.txt = 그중 test 제외 .ml 44,603줄).

## 1. 영역 지도

이 영역은 한 모듈이 아니라 가로 점검이다. 점검 대상 네 개:

| 대상 | 위치 | 크기 |
|---|---|---|
| 용어집 | `docs/spec/00-glossary.md` | 3,390줄·297KB (한 주 전 2,800줄·236KB), 표제어 약 235개 |
| 코드 모듈 | `lib/` 167개 dune 폴더, 단일 라이브러리 `masc` (`lib/dune`의 `(include_subdirs unqualified)`) | keeper 1,102파일·233K줄, server 439, runtime 163, dashboard 87 |
| 라이브 설정 | `~/me/.masc/config/` runtime.toml(2,339줄·65KB), candle.toml, keepers/*.toml 29개, tools/*.toml 208개, connection·repositories | 7일 안에 수정: runtime·candle·connection·repositories·overlay, keeper 17개(10-07), tool 25개 |
| 변경 이력 | git 7일 | fix 580 / test 199 / docs 121 / feat 106 / refactor 68 / merge 32 / perf 24 |

## 2. 7일 흐름 (커밋 수는 `git rev-list --count`)

- D-7 (09-29→09-30, 168): candle 29건(구매 계층 복구, 지급 산식), tui 40건. fix 64 / feat 25.
- D-6 (→10-01, 199): fix 119 / feat 12. tui 75건, glossary 10건. fix 비율이 60%로 올라간다. Home 대화·요청 열기, Jev 일괄 판정.
- D-5 (→10-02, 540): 한 주 최대. fix 197 / feat 24 / test 56. tui 120, candle 39, stack 26, item 19. 스택 복구·rebase 커밋이 몰린다(rebase 16, merge 32은 주 전체).
- D-4 (→10-03, 58): stack 15, tui 14. exact lane 후보 원자 교체.
- D-3 (→10-04, 118): fix 76 / feat 9. 메트릭 보존 설정, standalone lane 모델 편집, Candle 등급·지급 정책 설정(#40848).
- D-2 (→10-05, 14): 사실상 정지. 메모리 읽기·JEV 증거.
- D-1 (→10-07, 290): tui 90, keeper 21, dashboard 16. Goal 일시정지·차단 복구(#41151), Muse 사용률, Candle 운영자 지급(#41371)·Keeper 선물(#41409), 프리셋 삭제, IDE asks.

변경 요약 두 가지.
1. fix가 580건으로 전체 커밋의 43%다. fix 중 197건이 `fix(tui)`다. 7일 모두 바뀐 파일은 11개다: `bin/masc_tui.ml`·`_types`·`_render`·`_keys`, `bin/dune`, `lib/runtime/runtime.ml`·`.mli`, `test/dune` 등 (churn4.txt). 4일 이상 바뀐 파일은 164개다.
2. 10-04에 키보드 PTY 시나리오를 영역별로 쪼갠 refactor(#40234)와 10-06~07에 render·tui_decode를 쪼갠 refactor 뒤로 `fix(tui)`/`test(tui)` "restore …" 커밋이 10-07 하루에 10건 이상 나온다 (#41415 #41434 #41436 #41442 #41444 #41445 #41447 #41451 #41452 #41478). 쪼갠 쪽에서 테스트 기대 화면을 같이 못 옮겼다는 뜻이다.

## 3. 기능 매트릭스

| 기능 | 정상 경로 | 경계·코너 | N-Tick 순환 | 관측성 | TUI 연결 | 테스트 | 판정 | 근거 | 제안 | 크기 |
|---|---|---|---|---|---|---|---|---|---|---|
| 용어집 최신성 | 표제어 235개가 현재 코드 타입을 가리킨다 | Candle 항목이 원장 종류 9종이라 쓰는데 코드는 12종 | 닫힘 아님: Candle 코드 변경(#41371 #41409)이 용어집 갱신(#41024) 뒤에 들어옴 | 없음 | - | 용어집 존재 검사 없음 | 의심 | `lib/candle/candle_event.ml:28-71` vs glossary 1821행 | 고침: 종류 수 문장을 지우고 타입 이름만 가리키기 | S |
| 용어 이름 중복 | - | Jev 표제어가 543행, JEV/Noul이 3362행에 따로 있다 | - | - | - | - | 의심 | glossary 543, 3362 | 합침 | S |
| lib 모듈 층 경계 | dune이 폴더 의존을 강제하지 않는다 | runtime 아래 모듈이 keeper 모듈을 부른다(`runtime_candidate_backpressure_state.ml:32` → `Keeper_runtime_failure_route`) | - | - | - | 없음 | 의심 | `lib/dune` include_subdirs unqualified | 둠, 분할은 6.5절 | L |
| 냄새 스캔 (추가된 줄) | 부록 A | - | - | - | - | - | 의심 | 부록 A | 부록 A, 결함 D2·D4 | M |
| 변경 쏠림 | 4일 이상 바뀐 파일 164개 (7일 모두 11개) | refactor 뒤 test 복구가 반복 | - | - | - | - | 의심 | churn4.txt | 부록 B | M |
| 라이브 설정 정합 | runtime.toml·keeper toml·candle.toml 모두 로드된다 | 코드가 안 읽는 키 2개, 코드가 안 보는 배정 1개 | - | 알 수 없는 키는 로드 오류가 아니라 무시(runtime.toml) | - | - | 의심 | 부록 C | 결함 D1 | S |

판정 개수: 의심 6, 정상 0, 결함 0, 미확인 0. 결함 목록의 D1(설정 죽은 키)은 확정에 가깝다.

## 4. 결함 목록

P0, P1은 없다. 횡단 점검이라 한 곳에 터지는 버그보다 규칙 위반·정합 문제가 많다. 근거 상세는 부록 A~C.

### P2

**D1. 라이브 `[tui].voice_send_on_stop = true`가 아무 효과가 없다** (확신 높음)
- 상태: `~/me/.masc/config/runtime.toml`의 `[tui]`에 `voice_send_on_stop = true`가 있다. 코드는 `[voice.stt].send_on_stop`만 읽는다 (`bin/masc_tui_config.ml:170-193`, 주석이 옛 키는 읽히지 않는다고 적는다). `[voice.stt]`에는 `send_on_stop`이 없어 꺼진 채로 돈다.
- 결과: ^Y로 녹음을 끝내도 말한 내용이 자동 전송되지 않는다. 운영자는 켰다고 믿는다. 오류도 경고도 없다.
- 이유: runtime.toml 최상위 표·키에는 keeper TOML 같은 "모르는 키 거절"이 없다 (keeper 쪽은 `keeper_types_profile_toml_parser.ml:23-58`, `detect_unknown_keeper_toml_keys`가 거절). 같은 파일의 `[health].durable_queue_stale_sec = 600`도 코드에 읽는 곳이 없다 (`git grep durable_queue_stale` 0건).
- 최소 수정: 설정은 운영자가 `[voice.stt].send_on_stop`으로 옮기고 두 죽은 키를 지운다. 코드는 runtime.toml에도 keeper TOML과 같은 모르는 키 검사를 넣는다 (타입 표 하나로, 새 추상화 없이).

**D2. 운영 코드가 테스트 훅을 레코드 필드로 들고 다닌다** (확신 높음)
- `lib/lane_addon/lane_addon_broadcast_delivery.ml:3`: `type t = {root : string; io : Fs_compat.private_jsonl_transaction_io_for_testing option}`. 호출마다 `match io with Some io -> …_for_testing | None -> …`로 갈라진다 (:40, :43, :190, :220).
- `lib/fs_compat/fs_compat.ml:3609, 3680, 3762`: `*_for_testing` 함수 3개가 lib 공개 시그니처에 있다.
- 이 주에 `For_testing` 계열 모듈이 새로 18개 생겼다 (`Regular_read_for_testing` 포함): `candle_payout_worker.ml:124`, `goal_delivery.ml:59`, `keeper_librarian_context_recall.ml:151`, `keeper_runtime.ml:655`, `keeper_unified_turn.ml:481`, `lane_addon_broadcast_delivery.ml:333`, `lane_addon_store.ml:789`, `lane_addon_subscription.ml:325`, `posix_spawn_process_mgr.ml:237`, `server_browser_stagehand.ml:363`, `server_browser_webdriver.ml:249`, `server_candle_appraiser.ml:398`, `server_lane_addon_sampling.ml:217`, `server_lane_inventory.ml:147`, `server_routes_http_routes_play.ml:191`, `server_routes_http_routes_provider_runs.ml:194`, `dashboard_projection_cache.ml:154`, `auth_credential_base.ml:120`. 전체 트리는 `.mli` 216개에 `For_testing` 231곳이다.
- 문제: 워크어라운드 거부 체크리스트 6번(test backdoor 노출)에 해당한다. AI가 이 패턴을 선례로 배워 계속 늘린다. 위 18개는 이 주에 추가된 줄(`module For_testing = struct`)에서 찾은 것이다.
- 최소 수정: 새 `For_testing`을 더 받지 않는다. 주입이 필요하면 생성자 인자(함수 값)로 받고, 운영 경로에는 기본값만 둔다. 기존 것은 모듈 단위로 테스트 폴더의 fake로 옮긴다.

**D3. lib에 층 경계가 없다** (확신 중간)
- `lib/dune`: 라이브러리 `masc` 하나가 `(include_subdirs unqualified)`로 167개 폴더를 먹는다. 폴더 사이 의존은 dune이 막지 못한다.
- 증거: runtime(하위 층)이 keeper 모듈을 직접 호출한다 (`lib/runtime/runtime_candidate_backpressure_state.ml:32`의 `Keeper_runtime_failure_route`). config가 keeper 모듈을 연다 (`lib/config/keeper_runtime_setting_registry.ml`은 폴더가 config인데 이름과 의존이 keeper다). keeper↔runtime 쌍방 참조 (keeper→runtime 225파일, runtime→keeper 12파일, 주석 포함 근사치). keeper→workspace 153파일.
- 결과: 한 파일 수정이 컴파일 범위를 넓히고 테스트가 늘 같이 바뀐다 (3절 churn 참고). 정확한 계층 위반 수는 주석을 못 걸러 근사다.
- 최소 수정: 새 의존을 막는 lint 하나(폴더 쌍 허용표)를 먼저 넣는다. 분할은 6절.

**D4. `lane_addon_runtime.ml`이 JSON 연관 리스트로 레코드를 흉내 낸다** (확신 높음)
- `lib/lane_addon/lane_addon_runtime.ml:268-290`: `producer`를 `(string * Yojson) list`로 들고 `List.mem_assoc "visibility"`, `List.remove_assoc "source_access"`로 상태를 바꾼다. 문자열 키가 곧 타입이다.
- 파일 2,100줄, `Error "..."` 문자열 오류 65개 (`missing retained producer package`, `unknown retained producer output`, `private retained producer`…). 호출한 쪽이 이유를 구분하려면 문자열을 비교해야 한다.
- lane_addon 전체가 한 주에 3,729줄에서 6,315줄(+2,586)로 늘었다.
- 최소 수정: producer 레코드와 거절 이유를 variant 하나로 둔다. 문자열 `Error`를 variant로 바꾸면 컴파일러가 처리 누락을 잡는다.

### P3

| # | 위치 | 문제 | 확신 |
|---|---|---|---|
| D5 | `docs/spec/00-glossary.md:1821` vs `lib/candle/candle_event.ml:28-71` | 용어집이 원장 사건 9종이라 쓴다. 코드는 12종이다. 빠진 것: `Granted`(#41371), `Gifted`, `Gifted_item`(#41409). 용어집의 마지막 Candle 수정(#41024)이 이 둘보다 앞선다 | 높음 |
| D6 | `docs/spec/00-glossary.md:543`, `:3362` | Jev와 JEV/Noul이 2,800줄 떨어져 따로 정의된다. 하나는 어댑터, 하나는 모델이라 쓴다 | 높음 |
| D7 | `lib/keeper/keeper_turn_sandbox_runtime.ml:2985-3000` | 정리 보고서를 문자열 `"cleaned"`, `"clean failed"`로 센다 (파이썬 스크립트 출력과 문자열 약속). 마지막 `\| _ -> Error "…command failed"`가 종료 코드·신호·타임아웃을 한 문장으로 합친다 | 중간 |
| D8 | `lib/runtime/runtime_adapter.ml:420-422` | `match kind with OpenAI_compat -> … \| _ -> request_path_default_for_kind`: 새 provider kind가 생기면 컴파일러가 알려주지 않는다 | 중간 |
| D9 | `lib/keeper/keeper_official_client_tool_receipts.ml:37,43,63,64,82` | 외부 에이전트(Antigravity)가 보내는 `call_id` 순서가 틀리면 `failwith`로 턴이 예외로 끝난다. 호출은 `keeper_antigravity_runtime.ml:441,461`이고 둘러싼 `try`는 확인하지 못했다 | 낮음 |
| D10 | `bin/masc_tui_http.ml:666` | Broadcast principal을 `String.starts_with ~prefix:"principal:"`로 판별한다. 타입 있는 id가 아니다 | 중간 |
| D11 | `bin/masc_tui_http.ml:781` | MSX tick만 `status_code=409`를 `200`으로 바꿔 디코더에 넘긴다. 주석은 "typed activity refusal" 해석 때문이라 한다. 다른 호출은 409를 오류로 본다. 한 호출에만 있는 예외다 | 중간 |
| D12 | `lib/server/server_candle_appraiser.ml:202` | JSON-RPC 코드 `-32700 \| -32600 \| -32601 \| -32602`가 이름 없는 리터럴이다. 같은 값이 `Runtime_codex_app_server` 쪽에도 있는지는 확인하지 못했다 | 중간 |
| D13 | `bin/masc_tui.ml` | 27,520줄 (한 주 전 26,871줄). 키 입력이 문자열 `"j" \| "down" \| "wheel-down"` 94개 arm으로 갈린다. `masc_tui_keys.ml`의 `binding.key : string`이 표를 만들지만 "대부분 masc_tui.ml의 ordered match"라 스스로 적는다 (#30356에서 이미 표와 동작이 어긋난 적이 있다) | 높음 |
| D14 | `lib/dune`·테스트 | refactor로 파일을 쪼갠 뒤 10-07 하루에 "restore … PTY/harness" 계열 10건 이상 (3절 참고) | 높음 |
| D15 | `docs/evidence/` | 트리에 223.6MB. 이 주에 2,906파일 +169,843줄이 들어왔다 (png 434, log 787, json 576) | 높음 |

## 5. 낭비

| 무엇 | 크기 | 위치 | 고침 |
|---|---|---|---|
| 용어집 | 297KB·3,390줄 (한 주에 +61KB). 표제어 하나가 평균 14줄이고 한 항목이 수천 자인 것도 있다 (예: Candle 항목 1816-1860). 프롬프트에 주입되는지는 확인하지 못했다 | `docs/spec/00-glossary.md` | 표제어당 정의 3줄 + 타입 링크로 줄이고, 변경 이력(#번호 나열)은 지운다. 커밋 로그가 이미 가지고 있다 |
| git에 들어간 증거 파일 | 223.6MB, 한 주 +2,906파일 | `docs/evidence/` | 스크린샷·로그는 저장소 밖(artifact 저장소)으로. 이미 들어간 것은 history에 남는다 |
| 같은 Candle 등급을 LLM이 가른다 | `candle.toml`의 `grades_milli`가 trivial=100, small=700, medium=1000, large=1000, epic=1000. medium·large·epic은 지급이 같다. 등급 판정 단계(`lib/candle/candle_appraisal.ml:26-41` `Grade`)가 이 셋을 구분하느라 쓰는 모델 호출은 지급에 영향이 없다. 목표 하나당 단계 하나이므로 호출 수는 확인하지 못했다 | `~/me/.masc/config/candle.toml` | 운영자 결정: 값을 다르게 두든가 등급을 3개로 줄인다 |
| 단일 슬롯 exact lane | `hitl_auto_judge`, `board_attention_exact`, `workspace_curator_exact`가 슬롯 1개, `cli_slots` 비어 있음. 이 슬롯이 막히면 그 레인 전체가 멈추고 다른 후보로 가지 않는다 | `runtime.toml:89, 96, 2302` | 운영자 결정: 같은 계정 한도를 쓰는 후보를 한두 개 더 |
| runtime.toml | 2,339줄·65KB·413개 표. 위쪽은 사람이 쓴 스타일, 아래는 setup이 쓴 따옴표 키 스타일(`["models"."muse-spark-1.3_75bc5a82"]`). `[runtime.assignments]` 항목 몇 개가 `# ── provider ──` 주석 뒤에 끼어 있다 | `runtime.toml:104-125` (109행이 `# ── provider ──`) | 쓰는 쪽이 한 가지 모양으로 다시 쓰게. 읽기 쉬운 쪽을 기준으로 |

## 6. 용어·결합

### 6.1 한 이름에 뜻이 둘 이상

1. **Lane**: 다섯 가지로 쓴다.
   - (a) exact-output 고정 작업 경로 `[runtime.exact_output_lanes.*]` (`Standalone_lane.t` 7개: Librarian, Hitl_auto_judge, Board_attention, Workspace_curator, Verifier, Browser_stagehand, Candle_appraiser)
   - (b) 런타임 후보 순서 `[runtime.lanes.*]` (`Runtime_lane.t`)
   - (c) MSX·DOS·Browser 같은 기계/세션
   - (d) Lane Add-on 패키지
   - (e) 공식 클라이언트 레인·채팅 레인
   - 근거: glossary 1057-1085, 1107, 1363-1372, 1448; `runtime.toml` 54행 `[runtime.lanes.*]` vs 67-100행 `[runtime.exact_output_lanes.*]`.
   - 더 나쁜 점: `[runtime.assignments]`에서 Keeper에게 레인 이름이나 런타임 id를 한 칸에 쓴다 ("이름이 겹치면 레인이 먼저다", runtime.toml 주석). 이름 공간이 하나다.
   - 제안: (b)만 "후보 순서(fallback order)"로 바꾼다. (a)(c)(d)는 이미 `Lane_id.family` 넷으로 묶였다. 설정 키 이름 변경은 hard cut이라 호환 코드 없이 한 번에 바꾼다.
2. **Slot**: 넷이다. 기계 체크포인트 이름(glossary 1332), exact lane `slots`/`cli_slots`(runtime.toml), 초상화 착용 칸 `Face | Neck | Head | Hand | Base`(`lib/keeper_portrait/keeper_portrait_item.ml:3`), 이벤트 버스 슬롯(`lib/event_bus_slots`). 제안: 착용 칸은 `place`, 체크포인트는 `save name`처럼 겹치지 않게.
3. **Attention**: Board attention 후보, Operator Attention, Dashboard Attention, `external_attention`이 서로 다른 것이다 (glossary 표제어 5개).

### 6.2 한 개념에 이름이 둘 이상

- Exact lane / exact-output lane / Exact-output route (glossary 1057, 1544, TUI "Exact activity"): 한 이름으로.
- Item / 장신구 / accessory (`keeper_portrait_read.mli:1`, `keeper_portrait_item.mli:4`, 도구 설명 "portrait accessory") / `Keeper_portrait_item`: 코드는 item, 용어집은 장신구, 주석은 accessory.
- Candle 감쇠: 코드는 `half_life`·`Candle_decay`(52곳), 용어집·대화는 반감. 용어집의 "반감" 검색은 2건뿐이다. 운영자가 말하는 "halving"은 코드에 없다 (`halving`은 Board 페이지 검색 등 다른 뜻 17곳).
- Curator: 코드·용어집은 Workspace Curator(`workspace_curator` 68곳). "world curator"는 코드에 0곳이고, `lib/world_constitution`이 따로 있어 world와 workspace가 섞인다. 용어집에 표제어가 없다 (glossary 1059, 1545, 2976에 본문 언급뿐).
- Jev / JEV / Noul / TypeSafe AI / System One: 설정 표는 `[typesafeai]`, 코드 모듈은 `Typesafeai_*`(38파일), 용어집은 둘로 나뉜다 (D6).

### 6.3 용어집에 없는 코드 용어

이 주 새로 생겼는데 표제어가 없는 것: Workspace Curator, Candle Appraiser(`candle_appraiser` lane), Stagehand(Browser Stagehand lane), Muse(제공자), Verifier lane, Candle `Granted`/`Gifted`/`Gifted_item` 사건, Emblem 화면, Play invite(표제어 없음, 본문 3곳). 용어집은 Candle 항목 하나에 원장·지갑·구매·장비·공급량을 모두 넣어 길다.

### 6.4 번역투·어려운 표제어

옆자리 동료가 되물을 만한 제목 (phrasing-vocabulary 규칙): `Pre-Pagination Backlog Task Selection Query (페이징 전 백로그 태스크 선별 쿼리)`, `First-Page-Only Discovery Window`, `Selective Source Candidate Validation (질의 매칭 소스 후보 선별 검증)`, `Reverse Copy Judgment (역방향 사본 판정)`, `Carried Front (실어 보낼 이력의 시작 위치)`, `Shutdown Admission Fence (종료 진입 차단막)`, `닫힌 quota 창 (Shut Quota Window)`. 본문에도 "권위 철회와 캐시 무효화(Authority Withdrawal)", "단축 뷰포트 예산 보호", "에포크 무효화(epoch invalidation)", "공급량 투영(Supply Projection)"처럼 영어를 괄호로 단 번역투가 있다 (glossary 1862-1865). 쉬운 말로: "잔액을 다시 읽기 전까지 화면에서 지운다", "좁은 화면에서는 줄여 보인다".

### 6.5 도메인 결합과 분할 제안

의존 수는 `lib/` 폴더 단위로 파일이 다른 폴더 모듈 이름을 `Mod.`로 부르는 횟수다 (주석 포함 근사, edges.tsv). 한 주 사이에 늘어난 쪽:

| 쌍 | 파일 수 (주 초→주 말) | 읽기 |
|---|---|---|
| candle_runtime → candle | 0→36 | 새 영역. 정상 (새 모듈이 새 모듈을 부름) |
| candle_runtime → candle_config / candle_store / workspace | 0→11 / 9 / 10 | 새 영역 |
| server → runtime | 79→106 (+27) | 서버가 런타임 내부를 더 직접 만진다 |
| server → keeper | 407→417 | keeper가 server에서 가장 큰 의존 |
| keeper → core | 294→312 | |
| server → lane_addon | 12→20 | |

fan-out 상위: server 167, keeper 157, tool 67, dashboard 61, mcp 58, runtime 42. keeper는 1,102파일·233K줄로 lib의 가장 큰 덩어리다.

분할 제안 (손실 없이 나눌 수 있는 것부터):
1. `lib/keeper`에서 Candle·Item·Portrait 도구(`keeper_candle_*`, `keeper_portrait_*`)를 `candle_runtime`로 옮긴다. 이미 candle_runtime이 candle을 36파일에서 부른다.
2. `lib/keeper`에서 Librarian·Memory OS(`keeper_librarian_*`, `keeper_memory_*`)를 한 폴더로. glossary에서도 표제어 40여 개가 이 덩어리다.
3. `lib/runtime`이 부르는 keeper 모듈(`Keeper_runtime_failure_route`, `Keeper_operator_interrupt`, `Keeper_terminal_effect_detail`)을 runtime 쪽으로 내리고 keeper가 runtime을 쓰는 한 방향만 남긴다. 12파일 정도다.
4. `lib/lane_addon`(36파일·6,315줄)은 지금 server에서 20파일이 부른다. 선언·저장·실행 세 층으로 나누려면 `lane_addon_runtime.ml` 2,100줄이 먼저다 (D4).
5. 새 의존을 막는 허용표 lint를 먼저 넣는다 (D3).

## 7. 지울 것

- `For_testing` 새 모듈 18개와 `fs_compat`의 `*_for_testing` 3개와 `lane_addon_broadcast_delivery`의 `io` 필드 (D2). 테스트 쪽 fake로.
- 라이브 `runtime.toml`의 `[health].durable_queue_stale_sec`와 `[tui].voice_send_on_stop` (D1).
- 용어집의 PR 번호 나열과 사건 개수 문장 (D5, 5절). 용어집 Jev 표제어 하나 (D6).
- 문자열 키 연관 리스트로 만든 producer 레코드 (D4).
- `docs/evidence/`의 스크린샷·로그 (D15).

---

## 부록 A. 냄새 스캔 (추가된 줄)

방법: `git diff e126a20e72 fb5344a25a -- lib bin`에서 추가된 줄을 `파일:줄:내용`으로 풀고, 같은 내용이 삭제된 줄(옮기기·이름 바꾸기)을 뺐다. 남은 순수 추가 52,187줄, 그중 `.ml` 44,603줄을 봤다 (`F/nl.txt`). 주석 안 줄도 섞여 있어 숫자는 상한이다. 후보를 rg로 찾고 위 표 항목은 코드를 읽어 판정했다.

| 냄새 | 추가된 줄 수 | 판정 |
|---|---|---|
| `Obj.magic` | 0 | 없음 |
| TODO / FIXME / stub / unimplemented | 0 (`stub_file` 변수명 3줄은 `auth_credential_base.ml:470-976`, 실제 stub 아님) | 없음 |
| `failwith` | 20 (15는 `bin/lane_fusion_container_probe.ml`, 검증용 실행 파일이라 허용. 5는 `keeper_official_client_tool_receipts.ml`) | D9 |
| `For_testing` / `_for_testing` | 30줄, 모듈 18개 | D2 |
| 오류 문장·종류를 부분 문자열로 분류 | 0 (`contains_substring`·`lowercase_contains` 4줄은 검색 UI·검증 probe) | 없음 (확인함) |
| `starts_with` 로 종류 판별 | 실제 분류 2건: `masc_tui_http.ml:666` `"principal:"`, `masc_tui_render.ml:213` `"task-"`(표시용 짧은 id). 나머지 26줄은 파서·경로 검사 | D10 |
| `\| _ ->` / `\| _ when` | 460 | 아래 |
| 그중 도메인 variant를 받는 것 | 96 (`catchall_domain.txt`) | 대부분 `Some/None`과 섞인 "그 외 무시"로 무해. 문제로 읽은 것은 D7, D8 |
| 문자열 리터럴 match arm | 309 | 대부분 JSON `of_string` 디코더. 94는 TUI 키 입력(D13) |
| `Error "문자열"` | 527 (+ `Printf`/`^` 조립 88) | lane_addon_runtime 65, masc_tui 36, tui_decode 32, lane_addon_sampling 18 (D4) |
| 이름 없는 숫자 | 주석·날짜를 걷으면 적다. 아래 | |

이름 없는 숫자(주석 제외, 읽은 것):
- `lib/config/env_config_keeper.ml:313` `max 15 (min 3600 (get_int ~default:300 …))`: 하한·상한·기본값이 한 줄에 리터럴이다.
- `lib/server/server_routes_http_routes_provider_runs.ml:265` `window_minutes = 1440`: 하루를 분으로 센 값. `Masc_time_constants`가 있는데 안 쓴다.
- `lib/runtime/runtime_provider_usage_window.ml:707` `(100.0 -. remaining) /. 100.0`: 퍼센트 변환.
- `bin/masc_tui_http.ml` 400/401/403/409/500 상태 코드 리터럴 (D11).
- `lib/keeper_portrait/keeper_portrait_draw.ml:1237-1288`: 24.0, 0.35, 5.0, 19.0, 9.5 같은 좌표 계수 50여 개. 그림 좌표라 허용 범위지만 이름이 없다.
- 반대로 좋은 예: Candle 쪽(`candle_math.ml:35` `thousand`, `hours_per_day`, `candle_decay.ml:20` `fractional_bits = 128`, `candle_payment.ml:44` `in_range … 0 1000`)은 범위에 이름이나 근거가 붙어 있다. 같은 상수 중복은 큰 것이 없다 (4096 버퍼 7곳, 256 버퍼 6곳 정도).

### 나쁜 순서 15

| # | 위치 | 한 줄 | 쪽 |
|---|---|---|---|
| 1 | `lane_addon_broadcast_delivery.ml:3,40,43,190,220` | 운영 레코드에 test io 필드 | D2 |
| 2 | `fs_compat.ml:3609,3680,3762` | lib 공개 `*_for_testing` 함수 | D2 |
| 3 | `lane_addon_runtime.ml:268-290` | JSON assoc로 레코드, `remove_assoc` | D4 |
| 4 | `lane_addon_runtime.ml` 전체 (2,100줄, `Error "…"` 65) | 문자열 오류 | D4 |
| 5 | `keeper_turn_sandbox_runtime.ml:2985-3000` | 문자열 결과 센 뒤 `\| _ ->` 합침 | D7 |
| 6 | `runtime_adapter.ml:420-422` | provider kind `\| _ ->` 기본 경로 | D8 |
| 7 | `keeper_official_client_tool_receipts.ml:37,43,63,64,82` | 운영 경로 `failwith` 5개 | D9 |
| 8 | `masc_tui_http.ml:666` | id 종류를 접두 문자열로 판별 | D10 |
| 9 | `masc_tui_http.ml:781` | 409→200 한 호출만 예외 | D11 |
| 10 | `server_candle_appraiser.ml:202` | JSON-RPC 코드 4개 이름 없음 | D12 |
| 11 | `masc_tui.ml` 키 문자열 arm 94개 | 키를 타입이 아니라 문자열로 분기 | D13 |
| 12 | `env_config_keeper.ml:313` | 하한·상한·기본값 리터럴 | |
| 13 | `server_routes_http_routes_provider_runs.ml:265` | 1440 리터럴 | |
| 14 | `lane_addon_broadcast_delivery.ml` 포맷 | `let checked=match existing with`, `if bytes=""` 처럼 공백 없는 압축 스타일. 이 폴더 다른 파일(138자 이내)은 그렇지 않다. ocamlformat 기준을 안 따른다 | |
| 15 | `masc_tui.ml` 27,520줄 | 300줄 지침의 90배. 한 주에 +649줄 | D13 |

시그니처 3종(텔레메트리-as-fix, 문자열 분류기 보강, N-of-M)에 해당하는 추가는 이 스캔에서 못 찾았다. 다만 부록 B의 "restore"가 N-of-M의 변형이다.

## 부록 B. 변경 쏠림 (churn)

- 파일: 4일 이상 바뀐 파일 164개, 7일 내내 바뀐 파일 11개. 커밋 수 상위: `bin/masc_tui.ml` 232, `bin/masc_tui_render.ml` 199, `bin/masc_tui_types.ml` 174, `bin/dune` 98, `lib/tui_decode.ml` 74, `lib/tui_decode.mli` 68, `bin/masc_tui_loader.ml` 51 (commitfreq.txt).
- 한 파일에 커밋 232개는 하루 33개꼴이다. 에이전트 여러 명이 같은 파일을 동시에 고친다는 뜻이고, 이게 곧 충돌과 "restore" 커밋의 원인이다.
- 쪼개기 직후의 되돌림: `lib/tui_decode.ml` 12,712→7,496줄, `bin/masc_tui_render.ml` 17,146→14,196줄 (분할 refactor). 그 뒤 10-07 하루에 `test(tui): restore …` / `fix(tui): … expects …`가 10건 이상. 분할할 때 테스트 기대 문자열이 같이 옮겨지지 않았다.
- 이전 PR를 번호로 인용한 뒤 고치는 커밋은 261쌍이고 그중 fix·revert가 73쌍이다 (refpairs.txt). 대표:
  - #40039 Candle 공급 연결 → #40106(10-02) → #40696(10-03) → #40873(10-04): 같은 Item 화면을 4일 연속 고친다.
  - #40111, #40142: PR 하나에 "address Codex review"/"complete follow-up Codex review" 커밋 2~3개가 `[skip ci]`로 붙는다.
  - #40394 → #40400 → #40399: 테스트 링크 추가, 추가, 중복 제거 순서로 같은 의존을 3번 건드린다.
  - #41360 → #41362: Muse 사용률 기록 한 PR 뒤에 같은 날 리뷰 대응 PR.
  - #41478: 10-02(#40173, #40693, #40176)에 따로 고친 "신원 확인 뒤 읽기 다시 걸기"를 10-07에 한 곳으로 모은다. 5일 걸려 한 함수가 된 N-of-M이다.
- 빌드가 깨진 main 복구 커밋 8건: #40358, #40630, #40633, #40978, #41167, #41243 등. 주 후반에 main에 `dune build @check` CI를 넣었다 (#41309, 10-06). 그전 5일은 main이 컴파일 안 되는 시점이 있었다는 뜻이다.
- docs: 한 주에 3,062파일. `docs/evidence`가 2,906파일·+169,843줄이다 (D15).
- 시사점: fix 580건 중 197건이 TUI 한 표면이다. 표면 하나가 파일 세 개(`masc_tui.ml`, `_render`, `_types`)에 몰려 있어 병렬 에이전트가 같은 파일을 밟는다. 쪼개려면 화면(Home, Lanes, Work, Config…)마다 파일 하나로, 쪼갠 PR이 PTY 시나리오 기대 문자열까지 같이 옮기게 한다.

## 부록 C. 라이브 설정 (읽기 전용)

수정 시각 (KST, 2026-10-07 기준): `runtime.toml` 10-07 14:03, `candle.toml` 10-06 18:06, `connection.toml` 10-07 13:54, `repositories.toml` 10-07 14:19, `agent-core-models-overlay.toml` 10-07 14:21. `keepers/*.toml` 29개 중 17개가 10-07에 수정, 나머지 12개는 09-27~10-01. `tools/*.toml` 208개 중 25개가 7일 안에 수정.

이전 상태는 `runtime.toml.backup-20261002-*` 두 개뿐이라 키 단위 변경 이력은 그 사이만 본다. 10-02 백업 대비 현재:
- 삭제: `[runtime.lanes.glm-first]`, `[runtime.lanes.deepseek-first]`, `[providers.claude_code]`, `[providers.codex_subscription]`, `[codex_subscription.*]` 10개, `[models.claude-sonnet-5-5*]`/`claude-opus-5-*` effort별 표 수십 개.
- 추가: 계정 해시가 붙은 provider·모델 표(`codex_e641909e`, `claude_code_a8c76d7a`, `muse_d242bc1a` 등), exact lane 표(`candle_appraiser`, `workspace_curator_exact`), `[models.*]`에 `temperature` 키.
- 뜻: 한 주 사이에 "모델마다 effort 표" 모양에서 "계정 하나당 모델 묶음" 모양으로 바뀌었다. 파일이 setup 경로로 다시 쓰이는 모양이다.
- 키 개수 비교: 라이브 runtime.toml의 끝 키 이름 105종 중 코드(`lib`, `bin`) 문자열 리터럴에 없는 것은 22개다. 그중 21개는 Keeper 이름(`runtime.assignments.*`)과 HTTP 헤더 이름(`HTTP-Referer`, `X-Title`)이라 정상이다. 진짜 안 읽히는 키는 둘:
  - `[health].durable_queue_stale_sec = 600`: 읽는 코드 없음 (`git grep` 0건).
  - `[tui].voice_send_on_stop = true`: 옛 키 (D1).

keeper TOML 29개:
- 키 종류: `keeper.{instructions, sandbox_profile, sandbox_image, network_mode, mention_targets, name, activation_mode, board_interests, input_policy}` 대부분, 한 파일씩 `always_allow`(rondo), `voice_always_allow`(sangsu), `tools.native`(rondo).
- 모두 `keeper_types_profile_toml_parser.ml:23-58`의 허용 목록에 있다. 이 목록 밖 키는 로드가 실패한다. 모르는 키 문제 없음.
- `name` 키는 rondo만 없다 (파일 이름에서 파생하는 것으로 보이나 파서까지 확인하지 못했다).
- runtime.toml 배정(`[runtime.assignments]` 19개)과 대조: 배정은 있는데 keeper TOML이 없는 이름은 `imp` 하나. `imp`는 온보딩 내장 Keeper(`lib/operator/onboarding_status.ml:104-170`)라 정상. 반대로 TOML은 있고 배정이 없는 Keeper가 11개 (`context-reviewer`, `geek-scout`, `goo-yang-bong`, `hole-finder`, `jazz-developer`, `kidsnote-incoming-dd-manager`, `masc-pro-builder`, `ocaml-agent-ic`, `polisher`, `simplifyer`, `wkbl-front`). 기본 런타임 `glm-coding.glm-5.3-flash`로 돈다. 의도인지는 확인하지 못했다.

candle.toml (코드가 `required`로 읽는 키 `half_life`, `payout` 아래 전부와 `shop` 있음, 빠진 키 없음):
- `half_life = "off"` (감쇠 꺼짐), `deduction_rate = 0` (지연 감점 꺼짐), `weight_max = 1` (가중치가 0/1뿐이라 균등 분배), `grades_milli` medium=large=epic=1000, `shop.prices_milli`에 glasses·shades 0 (공짜).
- 읽기: 보상 경제는 켜졌지만(`candle.toml` 머리말: 2026-10-06부터) 차등 장치 셋(감쇠·감점·가중치)이 모두 꺼져 있고 등급도 3단이 같은 값이다. 설정이 코드의 정밀 산식(`candle_math.ml`, `candle_decay.ml`의 128비트 소수 자리)을 쓰지 않는 상태다. 운영자 결정 사항이라 결함으로 세지 않는다.

exact lane (`[runtime.exact_output_lanes.*]`) 7개: 코드의 `Standalone_lane`(7)과 이름이 모두 일치한다 (verifier_exact, librarian_exact, hitl_auto_judge, board_attention_exact, browser_stagehand_exact, candle_appraiser, workspace_curator_exact). 빠진 것 없음. 단일 슬롯 문제는 5절.

tools/*.toml: 키 종류 18개(`description`, `params`, `identity_fields`, `when_to_use`, `alternatives`, `key_constraints`, `prompt_hints`, `doc_refs`, `one_of`, `shell_command` 등)가 모두 `lib/`에서 읽힌다. 안 읽히는 키 없음.

확인하지 못한 것: keeper TOML 17개가 10-07에 어떤 키로 바뀌었는지 (이전본 없음), `runtime.toml`에 모르는 키를 거절하는 곳이 정말 없는지 (읽히지 않는 키 둘이 로드를 통과한다는 사실로 추정), 용어집이 프롬프트에 주입되는지.
