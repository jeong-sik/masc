# Goal verifier에 현재 측정값과 근거 위치 전달

현재 성공조건에 대한 최신 측정 기록이 Goal API에는 있지만 실제 판정 입력에는 빠지는 경로를 수리한다. 보고값과 독립적으로 확인한 값은 구분한다.

## 관측한 문제

기존 운영 실행 한 건은 acceptance 파일 읽기 2회와 공개 CI 페이지 조회 2회를 성공했지만, 필수 원문 상대경로 읽기 5회는 shared playground에서 `owned file is missing`이었다. 같은 review가 reviewed와 committed로 발행됐으며, 두 판정으로 세지 않는다. 그 실행은 APPROVE와 proof_proven으로 끝났다. `/tmp` 접근 거부나 권한 우회를 관측한 실행은 아니다.

또한 새 proof를 준비할 때 정확한 Goal/criterion의 최신 measurement와 그 evidence locator가 전달되지 않았다. 이것은 원문을 읽지 않고 승인한 모델 판단 문제와 별개의 입력 연결 결함이다. 운영 서버 c75의 세 Keeper context에도 main Goal의 성공조건은 있지만 최신 측정 ff5d는 없었다. 공개본은 main Goal 행만 보존한다.

## 구현

- 기존 Goal_measurement.latest_for_goal을 재사용해 정확한 Goal ID와 criterion revision의 observation을 전달한다.
- reported, not_recorded, unavailable을 구분하며 record의 값·근거·actor·시간을 기존 immutable Original.prompt에 담는다.
- 이 관찰값은 판정 맥락이며 lookup 권한이 아니다. 원문 조회 도구와 읽기 경계를 넓히지 않는다.
- 이미 retained된 Original의 prompt/digest와 v1 저장 형식은 유지한다. 새 측정이나 읽기 오류로 기존 proof의 복구를 깨지 않는다. 새 입력은 새 Original에만 반영한다.
- 모델은 실제 원문으로 비교한다. 측정 보고만으로 증명을 만들거나 숫자·조회 횟수로 판정을 강제하는 코드는 추가하지 않는다.

## 고정된 검증 범위

| 단계 | 식별자 / 결과 |
|---|---|
| 구현 소스 | 32282146ed980d48baa661aa7db0ce99376d3c2a |
| 직접 parent | fe6785bb3cbd881cc642b673b24328f7e19dbcd5 |
| 독립 코드 리뷰 | 위 head/base 전체 diff PASS; GitHub formal approval은 아님 |
| OCaml parse | 9개 파일 PASS; 로컬 Dune 실행 없음 |
| 선택 native | [40180462120](https://github.com/jeong-sik/masc/actions/runs/40180462120), 4 suites / 82 PASS (6+17+9+50) |
| macOS 실행물 | [40180463894](https://github.com/jeong-sik/masc/actions/runs/40180463894), 실제 선택 소스 32282146; workflow event head는 3cce9a51 |
| 실행 파일 SHA256 | c1ec353779d5fff6a9da9ec4290667ab9b5e158c28c34a7094a691d5d08277a4 |
| immutable 대조 JSON | 문서 commit ef5a4c707e29f1a4ff1fc5983b7ed0d64950fe38의 public-source-fixture.json, actual_value=1 |

native 소비자는 Original 준비, 실제 Worker/AR reviewer 전달·조회·복구, prompt section 전달, Goal proof gate다. Worker suite의 reviewer hook은 실제 HTTP 모델 증거와 구분한다. 전체 회귀는 이번 후보에서 미실행이다. 이전 전체 회귀의 신뢰 가능한 run/head/TARGET_SUITES는 이 증거 묶음에서 확인하지 못했다.

## 실제 모델 대조 실험

별도 base의 같은 32282146 실행 파일을 단일 glm-coding.glm-5-3 exact lane에 연결했다. URL은 Goal 제목·성공조건·완료 요청에 넣지 않고 최신 measurement.evidence에만 넣었다. 공개 원문 actual_value는 두 실험 모두 1이다.

| 실험 | 보고값 / 목표값 | 실제 모델 판정 | 저장 상태 |
|---|---|---|---|
| P | 1 / 1 | APPROVE | proof_proven / awaiting_confirmation |
| N | 999 / 999 | REJECT | proof_refuted / executing |

첫 P 요청은 fresh playground 디렉터리가 없어 모델 호출 전에 Proof_lookup_unavailable로 보류됐다. 빈 디렉터리를 준비하고 지원되는 request_complete를 반복했으며 Goal·criterion·request ID는 보존됐다. 이 실패와 복구도 실험 기록에 남긴다.

두 결과는 controlled fixture에서의 관측이다. 일반 허위 승인율, 다른 provider/client, 실제 업무 성과나 운영 적용의 증명이 아니다. 사람의 Confirm_completion은 수행하지 않았다. 실제 wire·원문 조회·Original·typed 저장 상태는 별도 추출본에 결속한다.

## 증거 파일

- runtime-identity / keeper-goal-context / main-goal-observation / source-boundary: 설치된 서버와 과거 context 관측 및 소스 경계.
- proof-run-observations / proof-reopen: 이전 실패 사례와 정상 Reopen. masc-tui actor 라벨로 물리 사용자나 동기를 추정하지 않는다.
- local-parse-receipt / independent-code-review-32282146 / ci-dispatch-32282146 / native-and-artifact-result: 후보 구현과 선택 검증.
- task2644-receipts: 실제 main Goal에 명시적으로 연결한 Task의 생성·claim·start. Task 수나 연결 비율을 성과 지표로 삼지 않는다.
- manifest.json: 각 공개 추출본의 바이트와 SHA256. 사설 원본은 원래 해시로 보존한다.

운영 설치는 관측 당시 c75였으며 이 후보를 설치하지 않았다. 이 PR은 원래 A1–A7 전체 감사 목적의 한 후속 작업이다. 기존 Qwen/Gemma 실패와 좁은 reported11/11을 전체 Goal 성공으로 바꾸지 않는다. 독립 Task는 계속 정상 상태다. 기존 main Goal·측정·성공조건을 이 실험의 쉬운 fixture로 교체하지 않는다.

브라우저: 실제 Vite 개발 대시보드를 같은 격리 backend에 연결해 P/N 측정값·근거·판정 화면을 캡처했다. packaged dashboard 자산은 초기 missing이었고 설치 증거로 쓰지 않는다. browser-observation.json과 두 PNG를 참조한다.

후속09:56:19 UTC 재조회에서 main 실행 파일은3cce9a51/SHA8086953b…(09:12:53 UTC 시작)였다. 앞선c75 context 관측은 그 시점의 기록으로 유지한다. 32282146 후보는 main에 설치되지 않았고, main Goal은 Executing/idle 및 기존ff5d 측정 그대로다. final-main-runtime-identity.json을 참조한다.

실제 carrier/lookup/verdict/registry/primary 결속과 독립 검토는 actual-verifier-controls.json 및 independent-actual-controls-review.json에 있다. 각 실험의 원문 조회는 1회이며 이후 요청 history나 reviewed/committed를 추가 실행으로 세지 않는다. 승인 verdict의 reason=null은 기존 타입 계약이고 실제 모델 사유는 evidence에 보존됐다.
