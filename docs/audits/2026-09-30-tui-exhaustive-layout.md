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

Board 최신 수정 head `40ebc2634e418770ca10eb7065a561cd5c6005a1`의 [집중 Linux PTY run 36647966652](https://github.com/jeong-sik/masc/actions/runs/36647966652)은 success다. [probe 36648531190](https://github.com/jeong-sik/masc/actions/runs/36648531190) artifact의 SHA256SUMS 네 파일을 확인했고, TUI의 `--build-commit`도 같은 head다.

같은 fixture 작성자 `wkbl-reader`, 같은 실측 **242×41**에서 [수정 전](../evidence/tui-audit-2026-09-30/board-comparison-before/board-detail-240.png)은 댓글 본문을 작성자 옆의 작은 잔여 폭으로 감싼다. [수정 후](../evidence/tui-audit-2026-09-30/board-comparison-after/board-detail-240.png)는 댓글 영역 전체 폭으로 감싼다. 기준 native 바이너리와 수정 Linux CI 바이너리를 각각 임시 fixture PTY에서 실행했다. 후자는 Docker Ubuntu 22.04에서 실행하며, 전용 proxy container의 loopback을 host fixture HTTP로 연결했다. 운영 서버·활성 사용자 세션의 캡처가 아니다. [재현 방법과 provenance](../evidence/tui-audit-2026-09-30/board-comparison.md)를 함께 보관한다.

Board PR check `36648042151` 및 Usage PR check `36648043868`의 edited-test 단계는 각각 89/91개 실행 뒤 같은 네 alias를 미통과로 나열했다. 실제 AssertionError는 account_login_pty에서 키 `2`를 보내 Keepers를 기다리는 fixture다. 다른 세 alias(account_login_removal_pty, activity_title_dot_belongs_to_the_strip, approval_detail_scroll_pty)는 PASS를 출력했지만, `run-edited-tests.sh`가 공유 Dune wave의 exit 1 뒤 전체 그룹을 미검증으로 분류했다. 이 결과는 전체 필수 체크 성공이 아니며, fixture 원인 대조와 수정이 남아 있다. 병합·운영 반영도 별도 확인 대상이다.

팔레트 새 PTY 시나리오는 기준 바이너리에서 40열의 입력 tail/caret 손실을 재현했다. 이 실패는 수정 전 재현 증거이며 수정 후 통과 증거가 아니다.

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
| K02 | Keeper logs | 75셀 고정 표 뒤 cost/work/tools가 도달 불가 | 구현 필요 |
| K03/S03 | Connectors/Clients | printf 최소 폭으로 긴 이름이 열을 밀고 channel/last seen 소실 | [#40118](https://github.com/jeong-sik/masc/pull/40118), 공유 Table.fit; 실행 검증 대기 |
| K04 | Schedules 상세/목록 | recurrence/ID/digest/fence 원문 잘림, mandatory target 폭 과다 | 구현 필요 |
| K05 | Runtime picker | mandatory 24셀×2 + chrome이 작은 frame 초과 | 구현 필요 |
| K06 | Chat inflight row | 다른 Keeper 이름 뒤 interrupt 행동이 잘림 | 구현 필요 |
| R02 | 기록된 diff | 세로 스크롤만 있어 긴 줄 뒤 차이가 도달 불가; shift 키가 file offset만 바꿈 | 실제 diff 수평 탐색 필요 |
| S02 | Runtime 목록 | 77셀 고정 열이 route/probe/detail을 밀어냄 | 반응형 열 필요; Enter 상세 fallback 있음 |
| W02 | Task 상세 | title/status/actor/reason/ID 등 고정 metadata가 원문을 잃음 | [#40133](https://github.com/jeong-sik/masc/pull/40133), 모든 metadata/history를 물리 행 스크롤에 포함; 집중 실행 검증 대기 |
| W03 | Goal 상세 | title/owner/metric/due/priority 등 고정 metadata가 원문을 잃음 | 필드 wrap 및 행 예산 재설계 필요 |
| W04 | 짧은 Goal 상세 | fixed13+timestamp3+linked8이 24행을 소모 | linked/body/footer 전체 행 배정 필요 |
| W05/W06 | Review/Verdict 상세 | title/task/request/agent/gate/goal metric metadata 잘림 | 필드 wrap 필요 |
| S04 | Runtime params | key/current/default 최소 폭, selected contract 도달 불가 | 표·선택 contract 재배치 필요 |
| S05 | Prompt registry/assets | key/source/file/vars metadata 원문 도달 불가 | 필드 wrap 필요 |
| S06/S07 | Presets | detail logical row 잘림; retained refresh failure에서 list_height+1행 | detail wrap·실패 상태/행 예산 수정 필요 |
| S08/S09/S10 | Voice | input tail/caret·endpoint metadata 잘림; assignment cursor 미추종 | [#40117](https://github.com/jeong-sik/masc/pull/40117), wizard/assignment; 실행 검증 대기, endpoint 추가 필요 |
| R03 | Workspace Activity | fixed clock/keeper/task 뒤 file 잘림 | 반응형 행·선택 path wrap 필요 |
| R04 | Code memo/history | subject/provenance 논리 행의 잘린 suffix 도달 불가 | 필드 wrap 또는 수평 탐색 필요 |
| S11 | Tools | root path/rejection/composition 행·skill usage last-used 잘림 | 상세 검사·wrap/반응형 열 필요 |
| O05 | Link preview | 설명 원문이 narrow frame에서 한 줄 잘림 | 설명 wrap 필요 |

## source review의 한계와 다음 검증

Calls exact fields, Fusion list/detail/launch, Memory overview/list, Runtime detail, Resources, Approval detail, Themes, Models, lane run list/detail, Code file body는 조사한 소스 경로에서 새로운 확정 결함을 찾지 못했다. 상세 tab·input mode·empty/unread/failed/stale 상태와 NO_COLOR까지 실행한 전수 PASS를 뜻하지 않는다. [inventory](../evidence/tui-audit-2026-09-30/surface-inventory.json)의 미조사 상태는 남겨둔다.

다음 단계는 (1) 남은 필드·표·행 예산·선택 문제 구현, (2) source-bound 수정 바이너리에서 전후 screenshot/PTY/로그 확보, (3) 각 현재 head의 PR checks와 targeted suite 원문 확인, (4) main 도착과 실제 설치/실행 바이너리 SHA 확인, (5) 전체 inventory completion audit다. 새 PR을 만들었다는 이유만으로 전체 목표를 완료 처리하지 않는다.
