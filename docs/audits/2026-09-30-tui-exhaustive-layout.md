# TUI 전수조사와 레이아웃 개선 진행표

전체 완료 상태: **미완료**. 화면을 모두 조사하고 개선한 뒤, 각 상세·오버레이의 실행과 현재 head CI, 변경 도착, 바이너리 화면을 따로 확인한다. 소스에서 결함을 못 찾았다는 사실은 동작 검증을 대체하지 않는다.

조사 기준 소스는 `65562ff5f7567f9b3a3b2c2b466d556d368d85ba`. 후속 main `2eb083ee7f209ccf0f20b51749bdace09ded3af1`의 관련 renderer/primitives/dispatcher 변경이 없음을 대조했다. 이후 head에서는 다시 확인해야 한다.

## 조사 범위와 수용 조건

[기계 판독 목록](../evidence/tui-audit-2026-09-30/surface-inventory.json)은 surface dispatcher의 **48개 renderer**, 전역 overlay 10개, renderer 안에서 별도로 검증할 detail/form/tab을 기록한다. 단순히 상위 메뉴 7개를 열었다고 전수검증이 끝난 것으로 보지 않는다.

- 폭 60/80/120/160/240열과 짧은 18/24행, 일반 32/48행에서 핵심 대상·상태·주 행동이 보이고 접근 가능해야 한다. 더 작은 지원 폭은 compact frame 또는 해당 입력창의 정책도 확인한다.
- 긴 한국어·ASCII 이름/ID/경로/JSON/소스 줄, 빈·읽는 중·읽기 실패·보존된 이전 값·여러 페이지를 다룬다. NO_COLOR와 focus 전환·리사이즈를 포함한다.
- 문서·근거·provenance의 잘린 부분은 줄바꿈 또는 실제 수평 스크롤로 도달 가능해야 한다. 세로 스크롤만 있는 화면에서 한 줄을 잘라 없애지 않는다.
- 페이지 이동과 선택 이동을 구별한다. 화면 밖 커서를 Enter가 실행하지 않으며, 선택 이동·새 항목 삽입·복귀 후에도 같은 대상 identity를 유지한다.
- 본문을 먼저 실제 표시 폭으로 렌더링하고 그 물리 행 수로 scroll을 계산한다. 고정 chrome·preview·footer를 포함한 행 예산을 보존한다.

## 현재 실행 증거

[기준 capture manifest](../evidence/tui-audit-2026-09-30/baseline/manifest.json)는 **수정 전 바이너리 + 임시 workspace + 합성 fixture HTTP + 실제 PTY/ttyd + Chromium**의 24장을 기록한다. 실측 크기는 80×41, 120×41, 242×41이다. 파일명 240은 요청 크기이며 manifest가 실측 권위다. 없는 fixture API의 HTTP 503과 observer stream 부재는 운영 장애 근거로 삼지 않는다. Keeper·Goal·Task 숫자는 합성 입력이며 서로 다른 fixture 모집단을 그대로 운영 일관성 판단에 쓰지 않는다.

- [Board 기준 상세](../evidence/tui-audit-2026-09-30/baseline/board-detail-240.png)
- [좁은 Usage 기준](../evidence/tui-audit-2026-09-30/baseline/usage-80.png)
- [좁은 System 기준](../evidence/tui-audit-2026-09-30/baseline/system-80.png)

아래 비교에 사용한 수정 head `40ebc2634e418770ca10eb7065a561cd5c6005a1`의 [집중 Linux PTY run 36647966652](https://github.com/jeong-sik/masc/actions/runs/36647966652)은 success다. [probe 36648531190](https://github.com/jeong-sik/masc/actions/runs/36648531190) artifact의 SHA256SUMS 네 파일을 확인했고, TUI의 `--build-commit`도 같은 head다. 후속 main 통합 head의 실행 증거를 대신하지 않는다.

같은 fixture 작성자 `wkbl-reader`, 같은 실측 **242×41**에서 [수정 전](../evidence/tui-audit-2026-09-30/board-comparison-before/board-detail-240.png)은 댓글 본문을 작성자 옆의 작은 잔여 폭으로 감싼다. [수정 후](../evidence/tui-audit-2026-09-30/board-comparison-after/board-detail-240.png)는 댓글 영역 전체 폭으로 감싼다. 기준 native 바이너리와 수정 Linux CI 바이너리를 각각 임시 fixture PTY에서 실행했다. 후자는 Docker Ubuntu 22.04에서 실행하며, 전용 proxy container의 loopback을 host fixture HTTP로 연결했다. 운영 서버·활성 사용자 세션의 캡처가 아니다. [재현 방법과 provenance](../evidence/tui-audit-2026-09-30/board-comparison.md)를 함께 보관한다.

Board PR check `36648042151` 및 Usage PR check `36648043868`의 edited-test 단계는 각각 89/91개 실행 뒤 같은 네 alias를 미통과로 나열했다. 실제 AssertionError는 account_login_pty에서 키 `2`를 보내 Keepers를 기다리는 fixture다. 다른 세 alias(account_login_removal_pty, activity_title_dot_belongs_to_the_strip, approval_detail_scroll_pty)는 PASS를 출력했지만, `run-edited-tests.sh`가 공유 Dune wave의 exit 1 뒤 전체 그룹을 미검증으로 분류했다. 이 결과는 전체 필수 체크 성공이 아니며, fixture 원인 대조와 수정이 남아 있다. 병합·운영 반영도 별도 확인 대상이다.

공통 로그인 fixture 수정은 [#40057](https://github.com/jeong-sik/masc/pull/40057), main `78c5270e98aa731e0c3a240edf6a6efcd253dfbc`로 들어왔다. 동일한 수정인 #40065는 source 파일 diff가 없음을 확인하고 닫았다. #40065의 필수 체크가 녹색이어도 merge guard는 `post_run_overlap`을 거절했다. 이 거절을 우회하지 않았다. Board·Work·Usage·Tables·Dashboard는 main `1a52f26bc9c609d5b37728f25f1def2d71893e24`를 통합했고 새 head CI가 필요하다.

팔레트 새 PTY 시나리오는 기준 바이너리에서 40열의 입력 tail/caret 손실을 재현했다. 수정 head `f5490ac599683e90f75d65e7071606650a30d7e6`의 [집중 run 36654450971](https://github.com/jeong-sik/masc/actions/runs/36654450971)은 success로 완료했다. 원문 PASS·화면·후속 head는 별도 확인해야 한다.

후속 집중 실행에서 확인한 실패와 응답은 구별한다. Keeper `36659398897`은 이미 Home인 화면에서 새 출력을 기다렸고, `3308aef6b4`에서 no-op 검사를 보완했다. Clients `36659294011`은 접힌 이름에 `long-`를 기대했고, `8f1bd0ee90`에서 관측 열로 행을 찾고 접힌 이름을 따로 검사하도록 바꿨다. Task `36660324248`은 초기 durable Task 읽기 전에 동적 팔레트를 열었고, `be39f068a1`에서 같은 backlog projection의 준비 신호와 완료 frame을 기다린다. 보완된 시나리오의 통과를 아직 선언하지 않는다.

Presets [집중 run 36662141540](https://github.com/jeong-sik/masc/actions/runs/36662141540)은 `f040b6f96679c2a3c46ad34fdf7a193a4e48d55e`에서 success로 완료했고, [원문 발췌](../evidence/tui-audit-2026-09-30/presets-targeted-pass.txt)에 checkout SHA·PTY PASS·unit OK가 있다. 40/60/80/120열, 짧은 창, 전체 값 복원, 정확한 페이지 overlap, 삽입 뒤 선택 identity, 응답 보류 중 읽기 유지, 실패 후 이전 내용, color/NO_COLOR fixture 범위를 검증한다. main `dc57509e2e5cb2b3086f5f4cf30142590a466b9a` 통합 뒤 `3128a81dda`는 [새 집중 run](https://github.com/jeong-sik/masc/actions/runs/36666351767)과 [probe](https://github.com/jeong-sik/masc/actions/runs/36666354114)를 요청했다. 이전 PASS가 새 head를 증명하지 않는다.

Runtime picker [집중 run 36662423793](https://github.com/jeong-sik/masc/actions/runs/36662423793)은 `60444ae71d6a24bb0380c3a0584f5631e2295657`에서 success다. 원문·화면·최신 base 확인은 별도다. Goal `36662267831`은 timeline을 고치며 공용 `short_ts` 구현을 제거해 interface와 Task history 호출을 깨뜨렸고, `e38b210cd1`에서 구현을 복구했다. Params `36661078061`은 40열에서 사라지는 제목을 resize 준비 신호로 썼고, 같은 실제 화면의 footer가 문서 위치까지 잘랐다. `8c909157d1`에서 준비 신호와 별도 위치 행·행 예산을 함께 고쳤다. 두 응답의 실행 결과는 아직 확인하지 않았다.

추가 확인: [집중 실행 원문 발췌](../evidence/tui-audit-2026-09-30/focused-passes-20260930.txt)에 각 checkout SHA와 실제 PTY PASS가 있다. Task `be39f068a1`, Keeper Info/Channels `3308aef6b4`, Clients/Connectors `8f1bd0ee90`, Goal `e38b210cd1`, Params `8c909157d1`, Keeper logs `8241076261`, main 통합 Presets `3128a81dda`의 해당 집중 실행은 success다. 이전 문단의 “미확인”은 당시 관측 상태이며 이 기록으로 갱신한다. 전체 상태 행렬·최신 main 겹침·필수 PR 검사·설치 바이너리 확인은 별도다.

Schedules `504b176078`의 새 viewport, hold, delivery는 PASS였으나 기존 source-status 시나리오가 실패했다. 이전 조회 유지 경고가 본문 스크롤 밖으로 사라진 실제 회귀이며, `f088db60a2`에서 고정 경고 행과 전체 오류 읽기·공유 높이를 함께 복구했다. [수정 실행36668855707](https://github.com/jeong-sik/masc/actions/runs/36668855707)은 요청 후 미확인이다.

필수 검사 후속: Tables `2c7f3ff122`의 `36664455073`은 `/repo/example`이 40열에서 `/re…example`로 정상 접힌 뒤 `/repo` 문자열을 요구한 검사에서 실패했다. 원문을 읽고 root·basename·fold 표시 및 더 넓은 폭의 전체 경로 검사를 보완했고, main 통합 `560667e1a2860e23a6773d7c31cd1d2e72e9c1f7`의 [집중 run36670468008](https://github.com/jeong-sik/masc/actions/runs/36670468008)은 success로 완료했다. [원문 발췌](../evidence/tui-audit-2026-09-30/tables-targeted-pass.txt)에 checkout SHA·40/56/74/100/160셀 실제 행·narrow repositories/logs의 OK와 96 tests run 성공이 있다. 이 실행은 compiled unit suite이며 PTY 화면 증거는 아니다. 현재 필수 검사·설치 바이너리까지 통과한 뜻은 아니다. 잘못된 추가 suite 이름을 쓴 `36670398026`은 취소했으며 증거로 쓰지 않는다.

Presets `3128a81dda`의 필수 run `36666262338`은 PTY holder의 bare Event.wait lint와 Config footer 기대값에서 실패했다. `f0f1cc6bce`는 PTY를 읽는 event 대기 helper를 쓰고 실제 `Home/End:detail` 안내를 기대값에 반영했다. 원문 실패 확인·독립 응답 리뷰·wait guard/Python/OCaml parsing은 완료했으며, [집중 run36670474174](https://github.com/jeong-sik/masc/actions/runs/36670474174)은 `f0f1cc6bce9cd6d82081b81b0c458f23a11611c5`에서 success로 완료했다. 이 후속 head는 metadata 확인이며 원문 PASS·화면 확인은 별도다. 집중 실행 PASS를 필수 체크 PASS로 일반화하지 않는다.

Board [#40088](https://github.com/jeong-sik/masc/pull/40088)은 조회 시 main에 merge commit `f960a2dada3583777c2abada69be2c557a8d4e59`로 병합되어 있었다. 필수 5 checks success를 확인했으나 설치 바이너리의 반영은 확인하지 않았다. Chat [#40186](https://github.com/jeong-sik/masc/pull/40186)의 `4e220fb942`는 전체 foreign stop 명령·물리 행 예산을 보완했으며 독립 리뷰/응답 리뷰 및 parsing을 마쳤다. 집중 `36669995389`는 테스트 stanza의 직접 모듈 의존성 누락(`Unbound module Masc_tui_roster_pane`) 때문에 컴파일에서 멈췄다. `b1b7dcfa0152d545731355a7663927dfd32eb16f`는 새 테스트가 쓰는 Roster/Frame/Message_layout 세 모듈을 모두 직접 선언했다. root와 독립 응답 리뷰가 exported interface를 확인했으며, [새 집중 run36674712037](https://github.com/jeong-sik/masc/actions/runs/36674712037)은 queued다. 아직 실행 PASS를 선언하지 않는다.

Schedules 경고 복구 `f088db60a2`의 [run36668855707](https://github.com/jeong-sik/masc/actions/runs/36668855707)은 success로 완료했다. [원문 발췌](../evidence/tui-audit-2026-09-30/schedules-repair-pass.txt)에 checkout SHA·viewport·기존 hold·source-status의 실제 PASS/OK가 있다. 해당 집중 fixture 범위를 증명하며 필수 PR 검사나 설치 바이너리 확인을 대신하지 않는다.

R02의 Code 부분은 [#40196](https://github.com/jeong-sik/masc/pull/40196)으로 별도 수정했다. 기존 Shift 화살표가 보이지 않는 파일 offset을 바꾸던 결함 대신 diff 전용 offset·실제 wire body 폭 clamp를 쓰고, old/new 번호와 +/- gutter는 고정한다. history/notes/Repository Changes는 뒤의 파일 pan을 거부한다. 독립 리뷰에서 마지막 overlay 조건 누락을 찾았고 직접 확인 후 공유 selector에 반영했다. 40/60/80/120열·color/NO_COLOR PTY fixture는 추가/삭제 끝부분·한글 셀 경계·clamp·파일 위치 보존·history/notes 이동 거부를 검사한다. Repository Changes guard는 소스 검토만 했다. 최신 head `abfe0affb1`에 집중 실행·probe를 요청했으며 실행 PASS와 화면은 미확인이다. 기록된 Changes와 Repository Changes의 diff 수평 접근은 여전히 남았다.

R02 후속 소스 전수 확인(`c112b2030652a5a25360f5d5322f8dc6da99c598`): `render_changes_diff`의 기록된 before/after는 `diff_row_span`이 +/-와 본문을 합친 뒤 `Span.truncate`로 끝을 버린다. `render_changes_tree_diff`와 `render_repository_changes_diff`는 공유 `diff_surface`가 `ds_scroll`만 받으며, `tree_diff_row_span`이 old/new/marker와 본문을 합친 뒤 잘라낸다. Shift 좌우의 key arm은 Code만 대상으로 하므로 #40196이 들어가도 세 경로에는 수평 접근이 생기지 않는다. [inventory의 diff_access_audit](../evidence/tui-audit-2026-09-30/surface-inventory.json)에 경로·현재 source seam·필요한 실행 검증을 각각 남겼다. blob 좌표만 기록한 materialized 호출은 원문 bytes가 없다는 별도 상태이며 데이터를 만들어내는 방식으로 이 결함을 고치지 않는다.

R02 세 후속 읽기는 [#40208](https://github.com/jeong-sik/masc/pull/40208)으로 구현했다. `ac8df5fb74`는 recorded/keeper-tree/project-tree fixture를 갖고, 40/60/80/120열과 color/NO_COLOR에서 전체 tail·gutter·더 긴 삭제 행의 clamp·재열기와 다른 파일 선택 초기화를 검사한다. root는 fixture를 직접 읽고, 첫 frame만 기다리던 burst 관측을 마지막 입력의 column + FRAME_END barrier로 강화했다. footer 기대값과 좁은 recorded 읽기의 별도 위치 행도 보완했다. [집중 run36673795966](https://github.com/jeong-sik/masc/actions/runs/36673795966)은 요청 후 미확인이다. 코드 게시를 실행 증명으로 보지 않는다. 새로고침·repository scope 전환 및 patch modal은 이 fixture에서 실행하지 않는다.

O05 링크 미리보기는 [#40209](https://github.com/jeong-sik/masc/pull/40209)의 `893ca15b5b`로 전체 URL·설명·거절 문구를 실제 폭에 맞춰 wrap했다. 독립 리뷰가 raw 개행/제어 문자와 한 행을 요구하는 거절 검사를 찾아, 기존 terminal sanitizer를 쓰고 전체 문구 복원과 별도 폭 검사를 유지하도록 수정했다. 독립 응답 리뷰는 source blocker 없음이며 30/40/60/80/120셀 URL 복원·UTF-8·전체 안내 검사가 있다. [집중 run36673794831](https://github.com/jeong-sik/masc/actions/runs/36673794831)은 요청 후 미확인이다. 실제 modal PTY·스크린샷·운영 설치 증거는 아직 없다.

후속 main `86751f610442e4d82992ebc54bf9eb8ba45ef6d2` 소스 대조에서 S02 Runtime 목록의 작은 폭은 여전히 10/20/20/22셀 고정 열이며 route/probe 앞에 들여쓰기·세 열·간격 55셀이 놓인다. R03 Workspace Activity도 날짜 16셀·Keeper 18셀·Task 16셀 뒤에 파일을 붙이고 선택 경로/Task 제목은 한 행이다. 열린 [surface studio #40177](https://github.com/jeong-sik/masc/pull/40177)의 `a5ff52d4f6cf83a11830a5254025110a0ec0aa79` diff는 repository 목록·Work·Params를 바꾸며 이 두 읽기 경로의 수리는 포함하지 않는다. 이것은 소스 대조이며 현재 바이너리의 실행 측정은 아니다.

R02 Code 후속: `abfe0affb12`의 집중 `36671784007`은 40열에서 diff 본문을 그렸지만 긴 pan 안내가 footer에서 탈락해 첫 시나리오가 실패했다. [원문 발췌](../evidence/tui-audit-2026-09-30/code-diff-narrow-hint-failure.txt)를 보관하며 tail/clamp/isolation 검사가 아직 실행되지 않았음을 명시한다. `bee36c85b7a02d37a33278e82bfd540af1731c42`는 diff 전용 안내를 `Shift-←/→:pan`과 `Esc:back`으로 줄이고 PTY가 두 안내를 모두 요구하도록 했다. 기존 key dispatch와 도움말은 유지되며 독립 리뷰 응답을 마쳤다. [새 집중 run36675879028](https://github.com/jeong-sik/masc/actions/runs/36675879028)과 [새 probe36676458728](https://github.com/jeong-sik/masc/actions/runs/36676458728)은 요청했으며 최신 head 실행과 스크린샷은 미확인이다.

S02 목록 부분은 [#40220](https://github.com/jeong-sik/masc/pull/40220)으로 수정했다. `68b11bce73`는 실제 frame 폭의 공유 Table.fit으로 후보 identity·route/probe를 먼저 보존하고 보조 detail/provider/lane을 순서대로 접는다. 헤더·데이터는 같은 열 배정을 쓰며 Enter의 정확한 lane/runtime 대상은 유지한다. 40/60/80/120열·lane/catalog·color/NO_COLOR fixture가 한 행의 이름 끝·healthy 상태·CJK 셀 폭·Enter에서 전체 ID 복원을 검사한다. 두 독립 소스 리뷰와 정적 검사를 마쳤다. 직접 실행에서 fixture의 None 환경변수·singleton probe 집계 불일치를 찾아 harness/decoder 계약에 맞춰 보완했다. 최신 `b9db8b2b0f0823d85108785f2bdea6797167c2ee`의 [집중 run36677494108](https://github.com/jeong-sik/masc/actions/runs/36677494108)을 요청했으며 앞선 `36676524947`/`36677120757`에는 취소를 요청했다. 수정 실행 PASS는 아직 없다. [확인용 probe36676780128](https://github.com/jeong-sik/masc/actions/runs/36676780128)는 이전 제품 head `68b11bce73`의 요청이며 후속 두 커밋은 fixture만 바꾼다. Default/media 고정 행, warning/fallback label·더 작은 창은 남은 범위다.

S02 기준 실행: 설치 main `86751f610442e4d82992ebc54bf9eb8ba45ef6d2`를 별도 임시 fixture PTY에 띄워 40×32 color/lane 읽기에서 정상 probe(1 reachable/0 failed/0 skipped)를 확인했으나 route/probe header와 상태가 프레임 밖으로 잘렸다. [텍스트 frame·provenance](../evidence/tui-audit-2026-09-30/runtime-list-before-86751.txt)를 저장했다. 바이너리 해시는 실행 전후 같았다. 이 실행은 원래 결함만 재현하며 수정 head·NO_COLOR·나머지 폭/모드·운영 데이터의 검증은 아니다.

R03 Workspace Activity는 [#40230](https://github.com/jeong-sik/masc/pull/40230)의 `c6677251ad98639c7cbc4390eecef7c690390caa`로 목록 파일/결과를 우선 배정하고 `v:context`에서 전체 repository/path·Keeper·Task 제목/ID·execution·기록 사실을 읽도록 했다. 페이지/키는 같은 물리 행 예산과 one-row overlap을 쓰며 선택이 사라지면 reader를 닫는다. 독립 리뷰가 overlay 입력 guard와 30열 초과를 찾아 직접 보완했다. 새 PTY는 30/40/60/80/120열×18행·color/NO_COLOR에서 전체 메타데이터 복원·Home·선택 초기화를 검사하며 실제 Task 읽기 신호를 먼저 기다린다. [집중 run36681385350](https://github.com/jeong-sik/masc/actions/runs/36681385350)와 [probe36680543354](https://github.com/jeong-sik/masc/actions/runs/36680543354)는 요청 상태이며 실행 PASS는 미확인이다. 처음 요청한 `36680299952`는 없는 `test_tui_keyboard_input-changes` alias를 포함해 취소를 요청하고, 선언된 `changes-newline` 가족으로 다시 요청했다. 이 이전 요청은 실행 증거가 아니다. Refresh/stale/overlay 차단·Enter 경로는 소스 검토만 했다. [설치 바이너리의 원래 경로 손실](../evidence/tui-audit-2026-09-30/workspace-activity-before.txt)은 해시를 고정한 복사본의 별도 fixture PTY 100×30 color에서 재현했고 원문도 저장했다.

O05 후속: `893ca15b5b998433196541e575bdfdf7419c52dc`의 [run36673794831](https://github.com/jeong-sik/masc/actions/runs/36673794831)은 success이며 [원문 발췌](../evidence/tui-audit-2026-09-30/link-preview-targeted-pass.txt)에 전체 URL/안내·거절 읽기·29-test 성공이 있다. compiled unit scope이며 실제 modal PTY/스크린샷·필수 체크·설치를 대신하지 않는다.

R02 세 읽기의 `ac8df5fb74` run36673795966은 recorded 40열 color의 tail/gutter/clamp/재열기를 통과한 뒤, 같은 24×40 크기의 keeper-tree에서 새 resize 출력을 기다려 멈췄다. [원문](../evidence/tui-audit-2026-09-30/recorded-diff-resize-failure.txt)의 실제 tree 본문은 이미 그려져 있었다. `6766ed25f4ab9515bc380284a60603a1a3f234aa`는 실제 PTY 크기를 읽어 같은 크기일 때만 이 대기를 건너뛰며 모든 실제 행·폭·tail·gutter 검사를 유지한다. 독립 응답 리뷰를 마쳤고 [새 집중 run36680037724](https://github.com/jeong-sik/masc/actions/runs/36680037724)을 요청했다. 나머지 reader/폭/NO_COLOR의 실행 통과는 아직 없다.

R04 메모 부분: [#40240](https://github.com/jeong-sik/masc/pull/40240)의 `3af8d721aec436688b12063caa15f57ebfc7523d`는 실제 file-pane 폭에서 메모 작성자·본문·읽기 실패 설명을 전부 wrap한다. 그린 줄과 같은 행 수로 j/k·Page·Home/End를 움직이고, resize 뒤 범위를 벗어난 위치에서 바로 움직이도록 보정한다. 독립 적대적 리뷰가 resize 후 k 및 footer 항목 공백 문제를 찾았고 수정·응답 리뷰를 마쳤다. 30/40/60/80/120/160열 color/NO_COLOR fixture는 전체 원문 복원·page overlap·끝에서 resize 뒤 k·재열기 초기화를 검사한다. [집중 run36683716774](https://github.com/jeong-sik/masc/actions/runs/36683716774)와 [probe36683719767](https://github.com/jeong-sik/masc/actions/runs/36683719767)는 요청 상태이다. 소스/정적 검사는 통과했으나 수정 head의 실행·스크린샷·필수 체크·설치는 아직 미확인이며, commit-history 제목·출처는 이 PR의 수정 범위가 아니다.

R04 history 부분: [#40247](https://github.com/jeong-sik/masc/pull/40247)의 `1b907b070f95ec32d0ba35808b458c5a70a2fc95`는 Commit/Author/Subject 및 Keeper/Task/Turn/Execution/Lines/Result, 파일·scope·coverage·file note를 실제 file-pane 폭에서 전부 wrap한다. Enter는 첫 표시 줄의 record owner를 해소하며, 진단/coverage 줄은 열 대상이 없다. 적대적 리뷰가 두 짧은 기록/마지막 기록의 선택 불가를 찾아 최종 물리 행까지 이동하도록 고쳤고 응답 리뷰를 마쳤다. 30/40/60/80/120/160열 color/NO_COLOR + 짧은 두 commit fixture를 추가했다. [집중 run36685970463](https://github.com/jeong-sik/masc/actions/runs/36685970463), [probe36685975680](https://github.com/jeong-sik/masc/actions/runs/36685975680)는 요청 상태로 수정 head의 실행·스크린샷·필수 체크·설치는 아직 없다. [기준 바이너리100×18 실측](../evidence/tui-audit-2026-09-30/code-history-before.txt)은 정상 읽기·1 exact Keeper change 뒤 원래 제목/출처 손실만 증명한다. Loading/failure·exact110열·1행·입력 overlay는 소스 검토뿐이다.

R02 재검증: run36680037724/head6766은 [9개 color pan receipt](../evidence/tui-audit-2026-09-30/recorded-diff-folded-path-failure.txt) 뒤 project40 목록에서 full `second.ml`을 기다리다 실패했다. 원문이 Dune에서 잘려 마지막 frame은 확인할 수 없다. 소스의 12셀 path 접기는 `lib…econd.ml`을 그리므로 incompatible needle이라는 추론이다. `602762aec2`는 두 대기를 `cond.ml`로 바꾸고 Enter의 고유 SECONDHEAD와 이전 REMOVEHEAD 부재를 유지한다. 독립 응답 리뷰를 마쳤고 [새 집중 run36685060343](https://github.com/jeong-sik/masc/actions/runs/36685060343)을 요청했다. 나머지 project 폭·NO_COLOR는 미검증이다.

R03 실행 후속: `c6677251ad98639c7cbc4390eecef7c690390caa` [run36681385350](https://github.com/jeong-sik/masc/actions/runs/36681385350)의 [실제 원문](../evidence/tui-audit-2026-09-30/workspace-activity-targeted-pass.txt)은 Activity layout·Repositories·Changes newline 세 suite PASS를 기록한다. Activity는 30/40/60/80/120열×color/NO_COLOR·18행의 10개 조합에서 목록의 failed/path tail/폭 및 Context의 전체 경로/CJK Task 제목/Execution·Task ID/결과·페이지·Home·기록 전환을 검증했다. 비교는 공백을 제거하므로 원문 공백 보존까지 증명하지 않는다. Refresh/stale/overlay·Enter 경로는 여전히 소스만 검토했다. 같은 head의 probe36680543354는 metadata success이나 artifact 다운로드가 실제 살아 있는 과정이어서 아직 manifest·binary hash/build-commit·스크린샷 증거가 없다. 필수 체크·설치·운영 환경 성공도 아니다.

S05 구현 후속: [#40254](https://github.com/jeong-sik/masc/pull/40254)의 `c0c3d9b1ed2edac61edc3e031fd140b0f206aa7e`는 registry/읽기 전용 assets의 전체 키·경로·소스·실제 변수·설명·오류를 literal wrap으로 상세 문서에 넣고 기존 본문의 Markdown은 유지한다. 페이지/Home/End는 같은 문서·물리 높이를 쓰며 j/k 선택은 상세 위치를 초기화한다. 독립 리뷰가 Librarian 실제 변수 누락과 거절 이유로도 통과할 수 있던 assertion을 찾아 필드명+값 및 별도의 Keeper 분류 문서 비교로 보완했다. 30/40/60/80/120열×color/NO_COLOR·18행 fixture에 전체 metadata/긴 오류·retained refresh/retry·asset·선택 초기화를 추가했다. [집중 run36689755419](https://github.com/jeong-sik/masc/actions/runs/36689755419)와 [probe36689759464](https://github.com/jeong-sik/masc/actions/runs/36689759464)는 요청 상태이며 수정 head 실행/스크린샷/필수 체크/설치는 미확인이다. 첫 읽기/loading/empty·실제 Librarian input fetch·overlay 입력은 소스 검토뿐이다.

## 수정과 남은 결함

`PR`는 구현이 게시되었다는 뜻이다. 아래에 적힌 PR들의 현재 head·CI·리뷰·병합 상태는 작업 직전에 다시 확인한다.

| ID | 영역 | 원인과 필요한 동작 | 현재 처리 |
|---|---|---|---|
| B01 | Board 댓글 | 작성자 옆 잔여 폭으로 여러 줄을 감싼 뒤 아래 행에 그대로 사용 | [#40088](https://github.com/jeong-sik/masc/pull/40088), focused PTY success; 같은 크기 전후 화면 확인, 도착 미확인 |
| W01 | Work 목록 | 긴 제목/담당자가 상태·우선순위를 밀어냄 | [#40089](https://github.com/jeong-sik/masc/pull/40089), 폭 배정·긴 owner 리뷰 반례 반영 |
| U01 | Usage | 한 줄에 130셀 이상, cost/coverage 도달 불가 | [#40091](https://github.com/jeong-sik/masc/pull/40091), wrap 후 scroll 계산 |
| S01/R01 | 로그/Workspace 표 | 고정 보조 열이 메시지/경로를 밀어냄 | [#40094](https://github.com/jeong-sik/masc/pull/40094), Table.fit 보조 열 접기 |
| D01 | Dashboard Goal | 긴 제목 뒤 측정값이 사라짐 | [#40095](https://github.com/jeong-sik/masc/pull/40095), 제목·측정 행 분리 |
| O01 | Palette | 긴 입력의 끝/caret 손실; 31열은 ellipsis만 표시 | [#40110](https://github.com/jeong-sik/masc/pull/40110), 입력이 masthead보다 우선; 31열/CJK 반례 반영 |
| O02 | Agenda | 첫 actionable target으로 뛰어 위 예정 일정을 못 읽음 | [#40102](https://github.com/jeong-sik/masc/pull/40102), reading/following 구별·visible-only Enter |
| O03/O04 | Answering | byte name 폭과 no-target scroll 부재; hidden Enter | [#40098](https://github.com/jeong-sik/masc/pull/40098), 셀 배정·page scroll·visible target; 테스트 dict 순회 오류도 수정 |
| M01 | Memory 상세 | claim 최소30셀이 실제 폭 초과; provenance 잘림 | [#40103](https://github.com/jeong-sik/masc/pull/40103), 폭 중복 차감 제거·필드 wrap |
| K01 | Keeper Info/Channels | 22셀 라벨 뒤 원문 값을 한 줄로 잘라 잃음 | [#40131](https://github.com/jeong-sik/masc/pull/40131), 필드 wrap 후 scroll 계산; 집중 실행 검증 대기 |
| K02 | Keeper logs | 75셀 고정 표 뒤 cost/work/tools가 도달 불가 | [#40160](https://github.com/jeong-sik/masc/pull/40160), 전체 필드를 물리 행 읽기로 투영·새 행 수와 key paging 공유; 집중 실행 검증 대기 |
| K03/S03 | Connectors/Clients | printf 최소 폭으로 긴 이름이 열을 밀고 channel/last seen 소실 | [#40118](https://github.com/jeong-sik/masc/pull/40118), 공유 Table.fit; 실행 검증 대기 |
| K04 | Schedules 상세/목록 | recurrence/ID/digest/fence 원문 잘림, mandatory target 폭 과다 | [#40167](https://github.com/jeong-sik/masc/pull/40167), 전체 필드 스크롤·실제 페이지 높이·원래 due/target/recurrence 우선순위 보존; 집중 실행 검증 대기 |
| K05 | Runtime picker | mandatory 24셀×2 + chrome이 작은 frame 초과 | [#40143](https://github.com/jeong-sik/masc/pull/40143), 실제 셀 폭으로 열 배정; 집중 실행 검증 대기 |
| K06 | Chat inflight row | 다른 Keeper 이름 뒤 interrupt 행동이 잘림 | [#40186](https://github.com/jeong-sik/masc/pull/40186), 전체 중단 명령을 먼저 wrap·공유 물리 행 예산; 실행 검증 대기 |
| R02 | diff 읽기 | 기록된 호출·Changes working tree·Repository Changes는 세로 위치만 있어 긴 줄 끝이 도달 불가; Code Shift 키는 가려진 file offset을 바꿈 | Code 부분 [#40196](https://github.com/jeong-sik/masc/pull/40196); 나머지 세 읽기 경로 [#40208](https://github.com/jeong-sik/masc/pull/40208), 실행 검증 대기 |
| S02 | Runtime 목록 | 77셀 고정 열이 route/probe/detail을 밀어냄 | [#40220](https://github.com/jeong-sik/masc/pull/40220), 목록 열 배정 수정·실행 대기; default/media 행은 남음 |
| W02 | Task 상세 | title/status/actor/reason/ID 등 고정 metadata가 원문을 잃음 | [#40133](https://github.com/jeong-sik/masc/pull/40133), 모든 metadata/history를 물리 행 스크롤에 포함; 집중 실행 검증 대기 |
| W03/W04 | Goal 상세·짧은 창 | metadata가 잘리고 fixed chrome/linked task cap이 본문을 밀어냄 | [#40142](https://github.com/jeong-sik/masc/pull/40142), 전체 metadata/연결 Task/타임라인을 물리 행 스크롤에 포함; 집중 실행 검증 대기 |
| W05/W06 | Review/Verdict 상세 | title/task/request/agent/gate/goal metric metadata 잘림 | [#40277](https://github.com/jeong-sik/masc/pull/40277) 전체 필드 wrap; CI 비활성화로 실행 미확인 |
| S04 | Runtime params | key/current/default 최소 폭, selected contract 도달 불가 | [#40135](https://github.com/jeong-sik/masc/pull/40135), 전체 필드 스크롤·실제 페이지 높이·refresh key identity; 집중 실행 검증 대기 |
| S05 | Prompt registry/assets | key/source/file/vars metadata 원문 도달 불가 | [#40254](https://github.com/jeong-sik/masc/pull/40254), 전체 literal metadata/오류·공유 detail 페이지, 실행 대기 |
| S06/S07 | Presets | detail logical row 잘림; retained refresh failure에서 list_height+1행 | [#40141](https://github.com/jeong-sik/masc/pull/40141), 전체 detail wrap·실제 페이지 높이·실패 행 배정·refetch 동안 읽기 유지; 집중 실행 검증 대기 |
| S08/S09/S10 | Voice | input tail/caret·endpoint metadata 잘림; assignment cursor 미추종 | [#40117](https://github.com/jeong-sik/masc/pull/40117), wizard/assignment; 실행 검증 대기, endpoint 추가 필요 |
| R03 | Workspace Activity | fixed clock/keeper/task 뒤 file 잘림 | [#40230](https://github.com/jeong-sik/masc/pull/40230), 반응형 목록·Context; 10개 fixture 조합/Repositories/Changes newline 통과, 추가 상태·설치 미검증 |
| R04 | Code memo/history | subject/provenance 논리 행의 잘린 suffix 도달 불가 | [#40240](https://github.com/jeong-sik/masc/pull/40240), 메모 작성자·본문 wrap/물리 행 탐색; 실행 대기; [#40247](https://github.com/jeong-sik/masc/pull/40247), history 전체 필드/줄 owner/파일·scope·결과 note, 실행 대기 |
| S11 | Tools | root path/rejection/composition 행·skill usage last-used 잘림 | [#40263](https://github.com/jeong-sik/masc/pull/40263) 전체 물리 행 wrap·composition 상세; 실행 검증 미확인 |
| O05 | Link preview | 설명 원문이 narrow frame에서 한 줄 잘림 | [#40209](https://github.com/jeong-sik/masc/pull/40209), 전체 URL·설명·거절 wrap, 실행 검증 대기 |

## source review의 한계와 다음 검증

Calls exact fields, Fusion list/detail/launch, Memory overview/list, Runtime detail, Resources, Approval detail, Themes, Models, lane run list/detail, Code file body는 조사한 소스 경로에서 새로운 확정 결함을 찾지 못했다. 상세 tab·input mode·empty/unread/failed/stale 상태와 NO_COLOR까지 실행한 전수 PASS를 뜻하지 않는다. [inventory](../evidence/tui-audit-2026-09-30/surface-inventory.json)의 미조사 상태는 남겨둔다.

다음 단계는 (1) 남은 필드·표·행 예산·선택 문제 구현, (2) source-bound 수정 바이너리에서 전후 screenshot/PTY/로그 확보, (3) 각 현재 head의 PR checks와 targeted suite 원문 확인, (4) main 도착과 실제 설치/실행 바이너리 SHA 확인, (5) 전체 inventory completion audit다. 새 PR을 만들었다는 이유만으로 전체 목표를 완료 처리하지 않는다.

### Focused Code-reader follow-up and Activity capture

Recorded/working-tree diff head602762aec2 completed all24 new fixture combinations and the126/17/5 compiled cases in focused run36685060343. See `recorded-diff-targeted-pass.txt/.raw`. This does not prove refresh, patch-modal or installation.

Memo run36683716774 failed from a fixture's fixed physical-column tree assumption; History run36685970463 failed before body checks because the narrow footer's mandatory labels needed34 cells. Their raw failure receipts remain separate from repaired-head requests36692603068 and36692381154. Unicode counter-derived boundaries, compact History actions, and concurrent literal-metadata fixes were integrated and independently reviewed. Execution of the repaired heads is pending.

Activity probe36680543354 downloaded successfully after the long active transfer. All four SHA256SUMS entries passed and the executable reported c6677251ad98639c7cbc4390eecef7c690390caa. `workspace-activity-ci-list.png` and `workspace-activity-ci-context.png` show isolated100x30 color fixture PTYs from that CI binary. The context screenshot shows rows1-23/25; the earlier focused suite supplies page-navigation evidence. Provenance and limits are in `workspace-activity-ci-capture.json`. These are not installed or production captures.

### Tools S11 source repair request

PR#40263 head40c77d8d738cbaea794be922ed0ca3b7e9b74b67 (base179544426a) wraps complete metadata at Frame.inner_width while retaining fitted tables/card borders. Revisions and recorded timestamps remain literal; usage cards show complete batches/nodes/dependencies. The full inventory-read error is included in the scrolling document. Renderer/navigation consume the same physical-row list.

New fixture covers10 usage-pane width/color combinations with distinct revision/long CJK path/diagnostic/unavailable-ledger/full timestamp/composition reconstruction, pages and Home/End. Other four panes and full inventory-read failure remain source-reviewed only. Response review caught an incorrect Memo-style counter regex; corrected Tools slash form directly parsed original native PTY22-30/30 and9body rows. Source/static guards and independent verification passed; no local build. Focused36694877409 and probe36694878753 are requests, not execution success.

`tools-before.txt/.raw`, `tools-before-screen.txt` and `tools-before-browser.png/.txt` reproduce original80x18 clipping using the frozen installed867 binary. Its Tools source blob equals this PR base. The browser capture uses refined distinct revisions; native capture preceded that fixture refinement. These do not prove repaired-head or production behavior. Full audit remains active.

### Memo, History and Prompts verification follow-up

The new Memo9bba run36692603068 completed six hidden-pane color widths, then default160 failed literal reconstruction because its extraction retained right Activity rows. The actual Recent header now supplies the exclusive right boundary; no payload filters or weaker assertions. Repair7c8a737df2 requests focused36696258326 and probe36696262199. NO_COLOR was not reached in the failed run. See `code-memo-recent-pane-failure.txt/.raw`.

History705 run36692381154 reached the first30-color case's final query check and found no GET records: the shared write ledger only observes POST/DELETE. Concurrent endpoint PathHttpResponse observers were integrated in a6379deb666ddb0de7a6159c6654ba5b33a951d7. Exact query assertions remain, and reader extraction also excludes the actual right Activity pane. Root exercised real three-endpoint GET callbacks, proving fixture observation only. Focused36696373189/probe36696377152 are requested; the remaining matrix is unproved. See `code-history-get-observer-failure.txt/.raw`.

Prompts c0c3 run36689755419 passed the full new10-case registry/asset PTY suite and held-back fixture; the overall run failed one of126 compiled keys cases because its exact Config union expectation omitted the new Home/End detail action. Head1be34f2ae7457c115b34910fe9320ee84de39921 changes that expected contract; focused36696374901/probe36696378672 are requested. Prior-head primary PASS is not newhead execution proof. See `prompts-pty-pass-key-expectation-failure.txt/.raw`.

Root inspected failure sources and raw outcomes; independent hostile and response reviews found no remaining source blocker after the repairs. No local build. The full audit, current-head required checks, integration, installation and production verification remain outstanding.

### Review/Verdict W05/W06 source repair and validation-route limit

PR#40277 headae678a798507e0f5633f180db0d2f5a9e9c67307 (base0c37b5c285) wraps complete metadata at the actual pane width before computing document count. Review retains full recorded Created, evidence headers and armed/action-error detail; Verdict retains literal title/reason/fallback and complete goal title/metric/target. The existing dispatch and confirmation handlers are unchanged.

The24-case fixture covers two panes ×six widths ×color/NO_COLOR with j/Home/End and exact whole-field reconstruction. The fixture waits for an accepted typed artifact row before Home/collection and reads only completed frames. Response review corrected heading-specific indentation in the left content boundary, and every j asserts its actual first row. Page overlap/refresh/stale/armed/error/actions remain source-reviewed only. Static guards and independent reviews passed; no local build.

`review-detail-before.txt/.raw`, `review-detail-before-screen.txt` and `review-detail-before-browser.png/.txt` reproduce original four-field clipping in complete100x18 color fixture frames from frozen867. They do not prove the repaired head or production behavior.

Both focused Test and manual probe dispatches were rejectedHTTP422 because workflows are disabled_manually. PR checks were absent. The active release-candidate lane has a tag/release/v* manual-entry guard and was not used for the ordinary fix branch. `review-verdict-ci-dispatch-rejected.txt` records the limit. No workflow was re-enabled. The verification-route decision is pending; the full TUI goal remains active and is not achieved.
