# Farm 실행 재개: 저장 권위·위임·문서 입력 감사

2026-11-16. 이 문서는 [11월 12일 Farm 계획](2026-11-12-agent-farm-plan.md)의
후속 조사다. 원래 25개 요구와 단계별 범위를 유지한다. 아래 수리 하나를 Farm 전체
완료로 세지 않는다. 코드 감사는 로컬에 있는 `origin/main`
`85f2823f053a693cecc8b63d6d0cb460dd10f9d0` 기준이다.

## 확인 범위

최근 일주일 변경, 공개된 열린 PR 목록, Schedule 저장·실행 소비자,
Keeper 위임 종료 전달, 문서 입력 capability와 wire, RemoteSSH 경로를 읽었다.
세 감사자는 구현 전에 각 경로를 따로 검토했다. 아래는 실행 재현 결과가 아니라
소스에서 확인한 경로다. 이번 작업은 운영 저장소를 수정하거나 서버를 재시작하지 않는다.

로컬 GitHub 통신은 DNS/연결 실패로 fetch를 마치지 못했다. GitHub connector로 읽은
main은 `0c875447ee7273da2d911d16e340410855b24885`였다. 그 head의 Schedule store와
로컬 기준은 Git blob `304130c45a32f2498a87314644e11444a19cfebe`로 같았다.
한 파일의 동일성은 전체 checkout의
최신성을 증명하지 않는다. 열린 PR 조회에서는 아래 Schedule 권위 수리와 같은 제목의
작업을 찾지 못했지만, 제목 검색만으로 모든 PR의 구현 중복을 배제하지 않는다.

## 먼저 고칠 경계: Schedule 복구 사본은 변경 권한이 아니다

관련 요구: 1(연속성·저장·잠금), 19(I/O), 20(백업·이식), 23(여러 큐와 proactive).
기존 계획의 G1·G6과 저장 축에 연결한다. 백업 구현이나 I/O 성능 개선의 완료는 아니다.

[Schedule_store](../../lib/schedule/schedule_store.ml)의 `write_state`는 primary를
저장한 뒤 `.last-good`를 쓴다. 두 번째 쓰기가 실패해도 primary에 적용한 변경은
성공으로 반환한다. 이 동작은 이미 적용된 일을 재시도하지 않게 하는 올바른 구분이지만,
두 파일이 같은 revision임을 보장하지는 않는다.

기존 `load_for_mutation`은 `Loaded (state, _)`로 출처를 버렸다. primary가 없거나
읽히지 않을 때 읽은 옛 `.last-good`도 변경의 바탕이 됐다. `refresh_due`와 기동 복구도
이 함수를 사용하므로 정상 primary만 받는 dispatch/settlement 검사 앞에서 이미
사본을 primary로 승격할 수 있었다.

실패 시나리오는 다음과 같다.

1. 일정이 Scheduled인 때의 복구 사본이 있다.
2. primary에서 그 일정을 취소하거나 실행·정산한다.
3. mirror 갱신은 실패해 사본은 옛 상태로 남는다.
4. primary가 없어지거나 읽을 수 없게 된다.
5. tick이 사본의 일정을 Due로 바꾸어 primary에 쓴다.
6. 이후 primary 조회는 성공하므로 예전에 끝낸 일정이 다시 실행될 수 있다.

수리는 공용 변경 진입점에서 복구 사본을 거절한다. 정상 primary와 아직 두 파일이
모두 없는 초기 상태는 계속 변경할 수 있다. 사본 조회는 진단용으로 남긴다.
원장이나 사본을 자동 삭제하거나 최신이라고 추정해 복원하지 않는다.
primary 성공 뒤 mirror 실패를 mutation 실패로 바꾸지도 않는다.

증명할 행동은 primary 누락·손상 두 경우에 대한 추가·수정·취소·note·due 전이·기동 복구
거절, 살아 있는 바이트 보존, runner 소비자 호출 0건이다. 정상 primary를 복구한 뒤에는
기존 취소·정산 사실을 읽고 정상 작업을 이어가야 한다. 시험의 상태 조작은 임시 저장소에만
한다. `test_schedule_store`와 `test_schedule_runner`가 검증 진입점이다.

자동 복구의 완성에는 권위 있는 commit lineage와 효과 대조가 필요하다.
이번 수리는 사본의 최신성을 추측하는 자동 복구를 없애는 범위다. 읽을 수 없는 저장소에서
계속 작업한다고 주장하지 않는다. [SQLite의 atomic commit 설명](https://www.sqlite.org/atomiccommit.html)은
여러 쓰기를 하나의 완료 사실로 보려면 별도의 commit protocol이 필요함을 보여 준다.
[Backup API](https://www.sqlite.org/backup.html)는 snapshot을 만드는 절차를 설명한다.
이는 설계 참고이며 MASC JSON 저장소가 SQLite의 보장을 갖는다는 뜻은 아니다.

## 다음 구현: 위임의 끝을 스트림 수명에서 분리한다

기존 TLJ-S01 / 요구 22. `Keeper_delegate_completion_wake.deliver`의 생산 호출부는
`server_routes_http_keeper_stream.ml`의 스트림 adapter 하나다. 초기 실행 실패와
기동 중 `keeper_chat_operation_store`가 확정한 Failed는 그 adapter를 지나지 않는다.
`keeper_owner_registry`의 재투영도 transcript/journal만 다룬다.

settlement와 기동 재투영에서 같은 terminal fact를 전달하도록 옮겨야 한다.
단, `keeper_registry_event_queue`의 중복 검사는 현재 pending 행만 본다. 전달 함수만
재호출하면 수신자가 ACK한 뒤 재시작할 때 중복 알림이 생긴다. 영속 전달 영수증 또는
소비 증거와 연결하고 enqueue 뒤 mark 전 중단도 다뤄야 한다.

완료 증명에는 초기 실패, stream 종료, 재시작의 실패/재개 가능 상태 구분,
enqueue/mark 사이 중단, ACK 뒤 재시작, 수신 저장 실패 후 재시도,
batch 원본별 operation ID가 필요하다. 이 작업은 협업 세션에 경로와 함께 전달했다.
전달된 요청은 구현이나 리뷰 완료가 아니다.

## 다음 구현: 문서 지원과 혼합 입력 지원을 나눈다

기존 WIM-S03 / 요구 3·13·17. `runtime_agent.ml`은 문서 admission을
`supports_multimodal_inputs`로 판단하고 `keeper_turn_driver.ml`도 같은 값으로
H5 reader 사용 여부를 정한다. 반면 Agent Core의 OpenAI serializer는
`supports_document_input`을 본다. 앞에서는 통과시킨 PDF가 뒤에서는 생략될 수 있다.

수리는 runtime schema/TOML, 해소된 capability, admission, H5 projector, 실제 wire와
runtime 관측을 같은 사실에 연결해야 한다. catalog에 있는 모델에는
`Runtime_adapter.declared_capabilities_override_of_model_spec`가 일부 필드만
override하므로 bool 두 군데만 바꾸면 불일치가 남는다.

개별 image/document를 지원해도 둘을 한 요청에 넣을 수 없는 경우를 함께 다룬다.
현재 H5 projector는 개별 미지원에만 반응해 bundle 거절을 풀지 못한다.
history·checkpoint·중첩 ToolResult도 같은 문서 경계를 지나야 한다.
관련 시험은 `test_runtime_modality_reroute`, `test_model_capability_presence`,
`test_h5_media_failover_continuity`, Agent Core의 `test_media_document_admission`이다.

별도 작업 WIM의 MCP media 보존도 남는다. `Mcp_client.tool_result.content`가 받은
원본 block을 `keeper_identity_tools.ml`은 text만 취하고 `content_blocks=None`으로 만든다.
Codex vendor tool 결과를 blob으로 남긴 #52137과는 다른 소비 경로다.

## 범위를 줄여서 완료 처리하지 않을 나머지

RemoteSSH `keeper_sandbox_remote.ml`의 작업·GitHub 설정 경로는 `remote_root`와
Keeper 이름에 의존한다. 같은 endpoint/root/name을 쓰는 별도 workspace의 충돌은
IA-S13/SP-S14의 영속 workspace·Keeper identity 설계로 다룬다. 임의 path hash를
붙이는 작은 패치로 다중 사용자 격리를 완료했다고 하지 않는다.

이 감사는 Candle/Stock, 전체 세계 export/import, TUI 음악 작업대, 외부 Dashboard 권한,
그래프·기억, 전체 문자열 외부화, 모든 provider와 addon의 연속 동작을 검증하지 않았다.
이들은 원래 계획의 해당 조각과 acceptance에 계속 남아 있다. 소스 변경, 독립 리뷰,
선택 시험, 설치, 원래 실패의 재현·회복, 여러 Keeper × 큐 × proactive의 장시간 실측은
각각 별도 증거로 기록한다. PR 수나 감사 건수는 제품 성공 수가 아니다.

## 이번 수리의 현재 위치

구현 커밋은 `921754a8947c89fc78ddb9992abd88c09d994c66`이다.
독립 소스 리뷰에서 P0/P1/P2 지적은 없었고 문법 검사는 통과했다.
동작 시험·PR 게시·병합·설치·실제 장애 회복은 아직 확인하지 않았다.
명령·검토 범위·남은 검증은 [증거 기록](../evidence/2026-11-16-schedule-primary-authority/README.md)에 있다.
