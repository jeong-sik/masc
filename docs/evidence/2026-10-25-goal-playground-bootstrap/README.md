# 새 Goal 검증 초기화와 실제 실행 보충 증거

새 workspace에서 Keeper를 만들지 않고 Goal 검증을 요청하면 공유 playground 부재로 모델 호출 전에 멈추는 결함을 수리한다. 제품 변경은 `Workspace_init.init`의 기존 디렉터리 생성 목록에 `Playground_paths.all_playgrounds_prefix`를 추가하는 것이다. 새 디렉터리는 base path에서 파생하며 검증기의 읽기 권한을 넓히지 않는다.

## 초기화 수정

소스는 `a0523385b9a5475fcb3998795d09307f262daf32`, 직접 base는 PR #45906의 `00af8ebcf387964fc7f0d67801b392e935f7d103`이다. 기존 실제 P 대조 실험의 첫 요청은 `Proof_lookup_unavailable`로 보류됐다. 빈 공유 디렉터리를 준비한 뒤 같은 request를 이어갔던 [이전 기록](../2026-10-25-goal-verifier-measurement-context/README.md)을 실패 원본으로 유지한다.

직접 소비자는 workspace bootstrap과 Goal verifier Original 준비다. 선택 검증은 다음 두 suite다.

- `test_workspace_bootstrap`: fresh init의 빈 공유 root, root가 사라진 뒤 re-init, 기존 state와 producer 증거 보존.
- `test_goal_verifier_original`: Keeper나 수동 mkdir 없이 공개 Goal `request_complete → create_goal_review → Original.prepare`; exact Goal/request/criterion 보존. root가 없으면 authority는 오류를 돌려주고 생성하지 않으며, re-init 후 같은 pending proof와 retained authority로 복구한다.

로컬에서는 변경한 3개 파일의 parse만 수행했다. [선택 native 실행](https://github.com/jeong-sik/masc/actions/runs/40186754980)은 exact source a052에서 두 suite 모두 성공했다. Workspace bootstrap은 assertion group 8개, Original은 Alcotest case 7개이며 `native-result.json`에 원본 로그와 선택 목록 해시를 기록한다. 전체 회귀는 미실행이며, 이전 전체 회귀의 run/head/TARGET_SUITES는 확인하지 못했다. fixture에서 모델을 호출하지 않는다.

## 같은 source3228에서 실제 Keeper와 Goal 판정 연결

별도 workspace의 검증된 실행 파일 `c1ec3537…`과 단일 GLM-5.3 Docker cohort에서 실제 모델을 사용했다. 초기 요청에 Goal ID를 넣지 않았고, runtime System의 관련/무관 Goal과 baseline으로 작업을 시작했다.

| 관측 | 결과 |
|---|---|
| 첫 Task | alpha만 true; beta/gamma는 false; 자동 reviewer가 실제 원문을 읽고 승인 |
| 남은 성과 | Keeper가 `1/3` 기록 후 두 번째 Task로 beta/gamma를 수정하고 `3/3` 기록 |
| 승인 순서 | beta/gamma 수정은 reviewer approve tool 종료 뒤 59.716103초이며, primary Done 원장 시각 뒤이기도 함; 두 시각 기준은 chronology-observation.json에서 구분 |
| 별도 Goal | factorial `40320`을 저장하고 관련 Goal에 별도 Task 연결 |
| 최종 Task | 자동 검증으로 3개 Done; Task 개수 자체는 Goal 성과가 아님 |
| Goal 증명 | 두 exact request의 retained Original, 실제 Read, 모델 verdict, primary proof commit 결속 |
| 사용자에게 반환 | operation Succeeded; 두 Goal은 proof_proven / awaiting_confirmation |

운영자는 이미 요청된 Docker `sleep 20` 명령을 1회 승인했다. 추가 의미 지시, 수동 Task 승인, Goal 사람 확인은 없었다. 완전 무개입 성공이 아니다. 판정 역할은 분리했지만 같은 GLM 모델이므로 cross-model 독립 검증도 아니다. 60 transport 요청 중 모델 POST는 59개이며, 이를 59회의 독립 검증으로 세지 않는다.

동결 원본 16개와 유지 원본 218개의 해시, 실제 call/result 66쌍, context projection 28개의 원본 결속은 `keeper-chain/actual-keeper-goal-proof-chain.json`에 있다. 새 bootstrap 수정 이전 source3228 실측이므로 이 새 코드의 runtime 성공으로 바꾸어 쓰지 않는다.

두 Goal의 submitted evidence는 빈 목록이다. 마지막 measurement가 실제 locator를 전달했고 Goal reviewer가 파일을 읽었다. factorial의 `workspace/factorial-result.txt`는 이 workspace에서 producer 디렉터리가 유일해 기존 owned-read resolver가 같은 공유 root 아래의 파일로 해석했다. 여러 producer에 같은 상대경로가 있을 때도 이 locator가 통한다는 보장은 아니다.

## Docker 채점 경계 재측정

source3228의 기존 consumer 3종을 선택했다. 첫 Node 이미지에는 Python이 없어 Docker verify가 exit127이었다. 나머지 Node oracle 복원/static symlink 거부 소비자는 통과했다. 기존 설치된 Python 이미지의 별도 cohort에서 Docker method를 다시 실행해 실제 container exit `0,0,0,0,7`을 관측했다. verify/regression/build는 동일 captured snapshot에서 각각 0이며, 새로 손상한 후보는 7이다.

이 fixture의 regression/build는 Python 경계 검사를 호출한다. 실제 프로젝트 compiler build나 전체 coding suite 성공을 뜻하지 않는다. Node oracle 검사는 host corpus consumer로 구분한다. 최초 실패를 지운 4/4 성공 집계를 만들지 않았다. 이미지 pull/build나 전역 Docker 정리는 하지 않았다. 상세 이미지 identity, snapshot/input 해시와 원본 receipt는 `coding-boundary/actual-coding-boundary.json`에 결속한다.

Docker grading은 구현된 경로다. microVM·SSH grading은 명시적으로 미지원이며 이번에도 실행 성공을 관측하지 않았다. Keeper의 guest execution 지원과 grading 지원은 별개다.

## 남은 결함과 증거 경계

- 보조 검색에서 rg가 실행되지 않은 Node exit1이 성공 lookup으로 기록됐다. 필수 직접 Read는 성공했지만 검색 실패를 성공으로 표시하는 P2 후속 결함은 남는다.
- 시간순 Task 계약의 reviewer가 이전 승인 원장을 직접 읽지는 않았다. 이번 실제 순서는 별도 원본 trace로 확인했으며, 일반 보장으로 확대하지 않는다.
- 없는 artifact 3회 재시도, 최종 측정 설명의 오래된 Task002 상태, factorial proof의 보조 Read 1회 실패, MCP status session 404 후 client 재초기화를 보존한다.
- 원래 Goal의 성공조건·기존 acceptance·측정은 바꾸지 않았다. 원래 필수 G1–G4/A1–A7 전체를 한 current head에서 재검증한 결과가 아니다. 일반 외부 acceptance 성공률도 아직 미측정이다.
- main 첫 관측은 d988이었고 다른 세션의 설치로 마지막 관측은 2e36766f로 바뀌었다. `main-observation.json`에 두 시점을 보존한다. 마지막 binary commit의 source를 직접 대조하면 새 bootstrap 변경과 coding sandbox helper는 포함돼 있지 않다. source 비교를 새 운영 동작 실측으로 바꾸지 않는다. 저는 운영 설치·재시작을 하지 않았다. 두 실험 Goal의 사람 확인과 원래 Goal 완료는 남아 있다.
- 이번 새 실행의 browser/TUI 렌더링 캡처는 추가하지 않았다. 이전 P/N 대조 실험의 실제 화면 증거와 구분한다.

공개 파일은 허용한 식별자·해시·관측값만 포함한다. 인증값, 사설 경로, 전체 모델/도구 원문과 thinking은 공개하지 않는다. 각 nested manifest는 해당 하위 폴더에, 최상위 manifest는 이 증거 묶음 전체에 적용된다. 독립 source/실측 리뷰는 GitHub formal approval이나 스택 전체 병합 승인을 대체하지 않는다.
