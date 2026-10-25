# Goal 판정에서 원본 Task 상태 읽기

선행 Task의 승인이 계약에 포함돼 있어도 판정자에게 제출자의 설명만 전달되는 공백이 있었다. 기존 실제 Keeper 실행은 순서를 지켰지만, 그 판정자가 선행 Task 원장을 직접 읽었다고 말할 수는 없었다. 이 변경은 명시한 `task:<id>`를 제출 시점의 원본 상태로 고정해 Task·Goal 판정자가 직접 읽도록 한다.

## 동작

- Task source가 있는 제출은 strict primary backlog를 한 번 읽고 모든 참조에 같은 관측을 사용한다. 정확한 ID가 없거나 중복되거나 primary를 읽을 수 없으면 오류다. recovery나 archive로 대체하지 않는다.
- 원본의 canonical Task 행, backlog revision과 표시용 last_updated를 보관한다. revision과 last_updated를 해당 Task의 승인 시각으로 바꾸어 부르지 않는다.
- 기존 `keeper_tasks_list` descriptor를 정확한 Task 하나의 읽기로 좁힌다. 제출한 source만 읽고 일반 목록·다른 Task·실시간 backlog·MASC 파일시스템을 열지 않는다.
- 고정된 Task source가 있는 제출에만 이 도구를 제공한다. Task source가 없는 기존 Task·Goal의 도구 schema와 보관된 검증 원본의 authority 검사는 유지한다.
- TUI의 Task 객체 링크는 현재 Task 상세로 이동한다. 제출 당시 증거 본문은 고정된 사본이며 현재 객체 조회로 바뀌지 않는다.
- 이후 승인·편집·삭제가 이미 제출한 원문을 바꾸지 않는다. SHA 검증과 UTF-8 JSON 페이지 이어읽기는 기존 frozen-source 경계를 사용한다. Goal 없는 Task와 계약 없는 Task는 계속 유효하다.

## 범위와 실패 보존

직접 base는 PR #45922의 `975c4751ca41e4e458c9e22103d7c50ba625f716`이다. 현재 검사 소스는 `3e0d83d9d00fd2c133a8bb8cb33147f9479e07e6`다. 서버 제품 수리는 e84에 있고, 0f72는 기존 Task Worker fixture의 모듈 경로를 고쳤다. 현재 3e는 빠졌던 TUI Task source 링크 분기와 실패한 fixture를 추가로 수리했다.

최초 `a2bfd30359b0e06d31c6e88cdc6f4501dc950e03`은 source 검토에서 두 P2로 거절됐다. Task 참조마다 primary를 다시 읽는 문제와 Task source 없는 판정에도 도구를 추가해 보관된 원본의 재개를 막는 문제였다. 원래 FAIL과 수리 후 소스 판정을 구분해 보존한다.

첫 [native 실행 40194054307](https://github.com/jeong-sik/masc/actions/runs/40194054307)은 새 음성 대조 fixture의 파일 쓰기 Result 미처리로 컴파일 실패했다. 두 번째 [40194890796](https://github.com/jeong-sik/masc/actions/runs/40194890796)은 추가로 선택한 기존 Task Worker fixture의 잘못된 모듈 경로로 컴파일 실패했다. 둘 다 테스트 실행은 0개다. 세 번째 [40195449903](https://github.com/jeong-sik/masc/actions/runs/40195449903)은 실제 65개 case를 실행해 62개 성공·3개 실패였다. authority 30개, Goal Original 8개, Task Worker 18개는 성공했고 제출·source suite는 9개 중 3개 실패했다. 이 부분 성공을 전체 성공으로 부르지 않는다. 실패한 fixture를 고치고 현재 소스의 제출·source와 TUI link 두 suite만 [40196376497](https://github.com/jeong-sik/masc/actions/runs/40196376497)에 다시 실행해 제출·source 9개와 TUI link 11개, 총 20개 모두 통과했다. [원본 case 행과 해시](native-pass-3e0d.json)를 보관한다. 통과한 나머지 세 suite는 0f72의 실행 기록이며 현재 head에서 재실행했다고 쓰지 않는다.

검사 대상은 `test_verification_collaboration_evidence`, `test_verification_authority_tools`, `test_goal_verifier_original`, `test_verifier_review_worker`, `test_tui_evidence_link`다. 실제 Task 요청 저장과 Goal 공개 dispatcher, 읽기 schema/권한, pending·Done 상태, 원본 변경·삭제·복원, 손상·중복·recovery 거절, 큰 원문의 실제 bridge 이어읽기를 다룬다. 두 Task의 같은 revision 검사는 정지된 입력 대조이며 동시 writer 실험은 아니다. Goal Original 검사는 현재 코드의 저장·복원·실제 조회이며 과거 실행물이 만든 원본의 재개 실측은 아니다.

로컬 Dune은 실행하지 않았다. 로컬 parse는 타입 검사나 실행 성공이 아니다. 전체 회귀는 미실행이며 이전 전체 회귀의 run/head/suite는 확인하지 못했다.

## 남는 계약

Done 행에는 특정 verifier와 verification ID의 typed 필드가 없다. 완료 시각과 노트를 읽을 수 있다는 사실을 정확한 승인 시도 인증서나 전체 승인 이력으로 승격하지 않는다. 실제 편집 시각의 독립 근거가 없으면 선행 승인 후 구현이라는 시간순 계약 전체도 입증하지 못한다. 노트와 문서 안의 승인 요구는 평가할 텍스트다.

Task Done은 외부 acceptance나 Goal의 사람 최종 확인이 아니다. 이번 소스·native fixture와 새 실행물의 실제 모델 동작·운영 반영·브라우저 표시도 별개다. e84의 첫 실행 번들 빌드 [40195108277](https://github.com/jeong-sik/masc/actions/runs/40195108277)은 빠진 TUI Task source 분기로 컴파일 실패했다. 그 분기를 수리한 현재 3e의 완전한 격리 실행 번들 빌드는 [40196379288](https://github.com/jeong-sik/masc/actions/runs/40196379288)에서 성공했다. 내려받은 artifact의 SHA 목록 12개를 모두 대조하고 같은 archive의 지원 파일과 실행 파일을 새 경로에 배치했다. 서버와 TUI의 내장 커밋 및 버전도 일치했다([로컬 확인 영수증](runtime-verified-3e0d.json)). 이 확인은 build-commit·version 실행이며 실제 모델 호출이나 운영 설치 성공이 아니다. 원래 Goal의 성공조건·측정·acceptance를 바꾸지 않았다.

## 공개 증거 읽기

[초기 FAIL](source-review/review.json), [최종 코드 source PASS](source-review/review-3e0d.json), [독립 리뷰 대응과 원본 case 재집계](review-response-3e0d.json)를 각각 보존한다. 이 판정들은 각 보고서의 head·base·전체 diff에만 결속된다. 앞선 판정의 미관측 실행 상태는 당시 기록이며 뒤에 완료된 native·bundle 영수증과 구분한다. GitHub의 정식 승인이나 전체 native stack 병합 승인이 아니다.

원문 raw CI 로그는 해당 Actions job에 있고 공개 영수증에는 bytes·SHA와 필요한 원본 case 행을 남겼다. private narrow-response 원본은 공개하지 않고 독립 대응 보고서에 원본 bytes·SHA를 결속했다. 공개 디렉터리의 모든 파일은 [manifest](manifest.json)에 열거한다. manifest 자신의 해시는 자기 파일에 넣지 않고 외부 PR·Task 영수증에 둔다.
