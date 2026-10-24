# Goal / Task terminal publication repair — source and evidence scope

이 문서는 새 수리 스택의 문서 전용 상위 PR에 담은 실제 결과와 source 범위의 증거다. 원래 Goal 11개 PR의 외부 병합과 고정 main 포함은 아래 감사 결과로 확인했다. 검토한 이전 수리 스냅샷은 `4cad4c4c…` 기준의 `6a2241fb…`이며, 새 수리는 처음 ac7 위에서 준비한 뒤 아래 실제 충돌을 반영해 고정 d587 위의 별도 candidate로 만들었다. 현재 실행·승인 head는 아래 44b6이고, 이전 준비·실패·내부 검토 기록은 역사적 범위로 구분해 유지한다. 이전 소스 CLEAR나 역사적 실행을 새 수리의 완료·승인·실행 성공으로 옮겨 쓰지 않는다.

## 현재 코드와 실제 결과

- Native Stack #45771: code [#45769](https://github.com/jeong-sik/masc/pull/45769) → evidence [#45770](https://github.com/jeong-sik/masc/pull/45770).
- 실제 실행·승인 대상 code head는 `44b6daee827adb9ef700c29f8d221220c2024df9`다. 직접 parent는 `6c9bf61e4cf155723af37125b3173a0730912ec7`, branch의 main 기준은 `d587bf1ffa123a05ae688cbc9fabe8e35221b206`이다. 문서 상위층 추가로 code head를 바꾸지 않았다.
- [run 40095356149](https://github.com/jeong-sik/masc/actions/runs/40095356149), job `120876318526`의 실제 checkout이 위 44b6임을 원문 checkout log로 확인했다. `2026-10-24T12:51:50Z` 완료. **105 PASS / 0 FAIL / 0 SKIP / 0 TODO**, 선택 5개 suite 모두 실제 실행·완료했다.
- Artifact `12560518815` [suite-runner-log ZIP](https://github.com/jeong-sik/masc/actions/runs/40095356149/artifacts/12560518815)은 23,905 bytes, SHA256 `8937746dd34dae50a5d4fc4bf218ec9bc970c63821eb022bc31d3bada348dcd3`다. archive 무결성·광고 digest·추출 runner bytes를 대조했다.
- [원문 runner log](40095356149/ci-run-tests.log)는 172,665 bytes, SHA256 `656f84ac3f1346832135c63fc7d809a40a229e8dcfcb8811b901b41a2abdc9c7`다.
- [실제 checkout·suite·case·archive receipt](40095356149/receipt.json), [읽기 결과](40095356149/readback.md), [P2 관련 실제 assertion 근거](40095356149/critical-assertions.json)를 원문 바이트로 보존했다. 이전 6c9 compile 실패와 cd155의 역사적 55 PASS는 아래 별개로 유지한다.
- 변경 4개 파일의 parser/whitespace 및 기존 13개 파일의 동일 바이트 확인에 더해, 이번 선택 5개 executable과 transitive dependencies의 실제 CI build가 통과했다. 전체 repository의 모든 target·전체 회귀를 빌드/실행했다는 뜻은 아니다.
- 각 PR은 자체 changelog를 가진다. 최종 상위층은 docs/changelog만 바꾸며 44b6의 17개 소스와 전체 13,956개 non-docs/changelog tracked input이 동일하다. workflow·runner·Dune 입력과 선언 fixture도 같다. 이는 source/input 동일성 증거이며 별도의 runtime 환경·최종 merge 결과 검증을 대체하지 않는다.

| 실제 실행 suite | PASS | FAIL | SKIP | TODO |
| --- | ---: | ---: | ---: | ---: |
| `test_goal_verifier_worker` | 16 | 0 | 0 | 0 |
| `test_goal_verification_agent` | 39 | 0 | 0 | 0 |
| `test_verifier_review_worker` | 18 | 0 | 0 | 0 |
| `test_completion_trust_harness` | 9 | 0 | 0 | 0 |
| `test_verification_run_registry` | 23 | 0 | 0 | 0 |
| 합계 | 105 | 0 | 0 | 0 |

## 실제 P2 회귀 측정 범위

Task Worker의 단일 case `execution 17`이 runner 1154–1247행에서 6개의 시나리오 블록을 끝내고 PASS했다. 고정 source의 List.iter 순서가 Judged → Committing → Commit_unknown 각각의 missing negative → observed positive를 연결한다. 로그 자체가 phase 이름을 따로 출력하지 않으므로 이 대응은 정확한 source와 함께 읽은 범위다. 6개 하위 시나리오를 6개 Alcotest 통과 수로 더하지 않았다.

- 실제 host 함수에 위임하는 같은 private runner의 scoped counter에서 음성 3회 모두 observe 0 / apply 0, 정상 대조 3회 모두 observe 2 / apply 1을 확인했다.
- 별도로 호출한 production `process_original_once` 음성 경로는 정확한 관측 누락 사유로 거부했다. Task 원문·Owner 이벤트·registry의 유무와 바이트 보존 및 추가 reviewer 0회를 검사했다. **production-entry 호출 자체에 callback counter를 설치한 것은 아니다.**
- 정상 대조의 실제 Task Done, production recovery 성공, durable Owner Completion ACK, 파일 replay 후 Approved 행은 case 안의 실패 분기와 ACK assertion으로 함께 확인됐다. [원문 해당 case](40095356149/missing-observer-case.log)에 출력된 값과 source에 있는 silent guard의 범위는 [구조화 근거](40095356149/critical-assertions.json)에서 구분했다.

실행은 private Workspace/실제 임시 파일·registry/제어된 reviewer·오류 transport·mock clock 등을 사용하는 production-path 회귀다. 실제 외부 모델, 설치된 서버/Keeper, 전체 회귀, 배포 또는 사용자 제품 QA 결과로 부르지 않는다.

## 현재 코드의 독립 source approval

[MASC brother 승인 `5638294412`](https://github.com/jeong-sik/masc/pull/45769#pullrequestreview-5638294412)은 `2026-10-24T12:49:57Z` 제출됐으며, firstline/footer가 정확한 44b6 head, base d587, canonical full diff `d6c3fb1ccda47623e0cf9755cbd580f3c0618483d72be6fe6a1efa783f9783ba`, Native45771 position 1/2에 묶여 있다. Footer가 본인 CR `5637557664` 대체를 명시한다. [전체 원문](44b6-source-approval.json)과 [source-receipt](44b6-source-receipt.json)를 보존했으며 Root의 `approve-guard --source-receipt`는 exit 0과 approval_ids=[5638294412]를 확인했다.

이 승인은 code #45769의 해당 source만 인증한다. 이 문서 상위층의 최종 head 승인, whole-stack merge-guard, 통합·설치 결과로 확대하지 않는다. 현재 source 승인과 실제 실행 증거는 서로 다른 단계이며 source approval 시각은 실행 완료보다 앞선다.

## 실제 6c9 실행 실패 — 5개 suite 모두 미시작

[run 40078689529](https://github.com/jeong-sik/masc/actions/runs/40078689529), job `120827487514`는 실제 checkout `6c9bf61e4cf155723af37125b3173a0730912ec7`에서 **컴파일 중 실패**했다. `Verifier_review_publication.terminal_expected`의 tuple fallback status wildcard가 fatal warning 4 (`fragile-match`)를 냈다. 새 수리는 닫힌 `R.Running | R.Completed _`를 명시한다. 이 실패 run은 수리 후 컴파일 증거가 아니며, 새 44b6 selected build는 위 실제 결과로 별도 기록했다.

공유 selected build가 먼저 실패하여 요청한 5개 suite는 모두 시작하지 않았다. 실행 case는 0, assertion 실패는 0, Alcotest SKIP도 0이다. 이는 5개 suite PASS나 5개 실패 case라는 뜻이 아니다. 도구 준비/의존성 설치는 진행됐고 실제 compiler diagnostic이 확인됐으므로 환경 오류로 바꾸어 부르지 않는다.

- Artifact `12554168212` ZIP: 5,031 bytes, SHA256 `29c5f3cec81a6fe90460200ff0e43353927d990f94f15223127f291ec82ef05c`; 다운로드 archive와 광고 digest 일치.
- [원문 suite runner log](40078689529-ci-run-tests.log): 30,560 bytes, SHA256 `ad8258390b9bb66aa6f68ac2a0d7c26b370b80d0691b0a2cd4317ae0ae0caa3b`.
- 원문 job log: 103,874 bytes, SHA256 `6b15673c47179e382eb063050380239420734f2b5fc05504e58dd08778fa5b5a`.
- [정확한 실패·checkout·suite별 미실행 receipt](40078689529-failure.json)에 원문 archive/job/checkout/log 해시를 모두 보존했다. 원래 실패 기록을 삭제하거나 덮어쓰지 않았다.

## 독립 MASC P2와 이번 수리 경계

[MASC brother Changes Requested `5637557664`](https://github.com/jeong-sik/masc/pull/45769#pullrequestreview-5637557664)는 `2026-10-24T08:39:09Z`에 정확한 6c9 head를 검토했다. [원문 판정](6c9-brother-changes-requested.json)을 보존한다. 초기 4cad/6a·ac7·6c9 내부 source CLEAR는 이 P2를 놓쳤으며, 정식 승인이나 이 경로의 안전성 증거가 아니었다.

유효한 judgment/commit intent가 있는 `Committing` 또는 `Commit_unknown`에 Registration이 없으면 이전 Caa가 `Unobserved -> Ok ()`로 통과했다. 실제 Task apply 뒤 publication에서야 관측 정보 부재가 드러났다. 이제 모든 적용 가능 retained phase는 같은 canonical `captured_before`를 통해 실제 execution/before receipt를 검증한 뒤 Worker/domain 경계로 들어간다. 관측 사실이 없는 기록의 도구·시각을 복원해 꾸미거나 호환 fallback을 두지 않는다.

기존 missing-observer case를 실제 Owner 이벤트로 만든 Judged/Committing/Commit_unknown 각각의 음성 및 정상 대조 사례로 확장했다. 같은 private host runner에서 음성 사례는 strict intent와 실제 before가 유효함을 먼저 확인한 후 정확한 missing-observation 오류, real-delegating observe/apply 호출 0회, Task 원문·Owner 이벤트·registry 유무/바이트 보존, 추가 reviewer 0회를 검사하도록 선언했다. 실제 production `process_original_once` 거부도 유지한다. 관측 정보가 있는 대조 사례는 같은 runner의 실제 apply 1회, before/after 관측 2회, Task Done과 실제 terminal registry ACK를 검사한다. 이 수리 작성 당시에는 준비한 assertion이었으며, 현재 44b6의 실제 측정 범위는 위 run40095356149에 구분해 기록했다. suite의 Alcotest case 선언 수는 18개 그대로다.

MLI 변경은 `For_testing`의 scoped effect wrapper entry뿐이다. Production alias는 기존 real observe/apply에 고정되어 있고 새 global hook, registry, 원본 wire schema 또는 product 설정은 없다. Root와 독립 main_build가 정확한 v2 패치를 source CLEAR로 읽었지만 새 head의 formal approval, CR 해소 또는 실행 PASS를 뜻하지 않는다. 당시 필요했던 CR author의 재판정은 위 승인5638294412로 확인했으며, 그 source 범위만 인정한다.

## 이전 ac7 기반 코드 준비 스냅샷

- 기준 main: `ac7fe109acc9a54d479317755a24efb556c004b0` (한 번 캡처한 `2026-10-24T08:08:05.221807Z` 상태).
- 코드 준비 commit: `4e69d102c3efa964573ff2124171ea4ac6de4b29`; tree `d640eb0ee6fcaba3b0c1c23b1325f9c2a1e8fe93`. PR 번호별 changelog가 아직 없는 준비 commit이며 최종 배포·검증 대상 SHA로 부르지 않는다.
- main 대비 17개 소스·테스트 파일 패치 SHA256: `f683a2789b69a64fa679845430c62633e1628161156e62f7a69c4b194546a97a`.
- 이전 `6a2241fb…` 대비 14개 파일은 byte-identical이다. 변경한 3개는 Caa의 외부 private helper 반환 계약, 외부 trust-harness 검증 보존, 이에 맞춘 terminal/stale-call fixture 기대값이다. 이식 차이 SHA256: `f0aac0e5e23649ae89b2ac2b5b9588c95103cd697f712427c4c0b48cc355711a`.
- 실제 author/committer: `masc-pro-builder <besleepers@gmail.com>`. 이는 신규 source-admission에서 해당 계정을 독립 검토자로 세지 않는 근거다.
- 당시 실제 확인: 17/17 OCaml 5.5.1 parser 통과, whitespace 검사 통과. 현재 파일별 해시와 이전 확인의 재사용 범위는 [검사 기록](source-checks.json)에 구분했다. 당시 타입 검사와 새 소스 실행 결과는 없었다. 현재 44b6 결과와 구분한다.
- Root 및 독립 에이전트의 source CLEAR는 위 소스 이식 범위에 대한 내부 검토다. 새 PR의 current-head 독립 approval, merge-guard 통과 또는 실행 PASS를 뜻하지 않는다.

실제 외부 병합 Caa의 부분적인 `Execution_pending` 재관측 fallback은 reviewed typed/atomic/ACK 경로로 교체했다. `For_testing.process_original_once`와 `commit_original`의 `Superseded_by`→Error 계약은 유지했다. 새 terminal/stale fixture는 이 정확한 Error와 실제 durable `R.Superseded_by`, Owner ACK, Task 보존·추가 reviewer/registry effect 없음까지 함께 검증하도록 선언했다. 외부 trust-harness의 retained `Conflicted`와 boot pending 제외 검증 13개 줄 및 reviewer callback label 두 개를 보존하고, pending 판정에 canonical `needs_publication`을 적용했다. 당시 이 문장은 source assertion 범위만 가리켰다. 현재 실행 성공의 범위는 위 exact44b6 artifact에 별도로 기록했다.

## 검토한 이전 수리 스냅샷

- 이전 소스 검토의 비교 기준 main: `4cad4c4ce9cdf8f9c1a1d96a94e4a5a8a54b09e6`. 새 수리의 기준 main과 구분한다.
- 로컬 기존 49개 커밋의 head: `3d70febc616ad13c84a74c3ef67985770c1d5466`.
- 검토한 이전 수리 소스: 17개 파일. 확정 패치 SHA256 `6a2241fb310447fe0d8a5a377f8f8ac16a1f7debd001d3498c0dcdf241f2db96`.
- 확정 시각: `2026-10-24T07:59:06.373759+00:00`.
- 기록: `/tmp/goal-task-composition-frozen-source-receipt.json`, 패치 `/tmp/goal-task-composition-review.patch`.
- 독립 소스 검토 두 건이 CLEAR로 보고되었다. 이 판정은 현재 PR의 정식 approval, 타입 검사, 실행 성공을 대신하지 않는다.
- 기록된 로컬 확인은 17/17 파일의 OCaml parser 통과와 whitespace 검사다. 독립 검토에서 17개 실제 파일 해시와 위 head 일치를 확인했다. 로컬 Dune 빌드와 테스트 실행은 하지 않았다.

새 `ac7fe109…` 기반 소스 이식과 내부 source 검토는 위 준비 스냅샷에서 확인했다. 당시에는 타입 검사·새 실행 성공이 미기록이었다. 현재 exact44b6 실행은 위에 별도로 기록했다. 아래 선언 수는 새 준비 코드의 실제 test_case 선언을 다시 읽은 수치이며 통과 수가 아니다.

## 원래 Goal 11개 PR의 외부 병합 감사 — 확인된 사실

`jeong-sik`이 2026-10-24 **07:52:35–07:52:46 UTC**에 원래 Goal 11개 PR을 외부에서 병합했다. 대상은 #45442, #45471, #45524, #45573, #45637, #45650, #45654, #45671, #45684, #45708, #45710이다. 고정 main `ac7fe109acc9a54d479317755a24efb556c004b0`에 11개 실제 merge commit이 모두 포함되어 있다.

- 실제 외부 병합 top source head: `12b867257dab1eb5ce57ed2e60c6d0b34da81260`.
- top #45710 merge commit: `242d12659fd1bdd2e43ef6553c04a4ce92552ed0`.
- **실제 병합된 정확한 head에 대해 merge 이전에 유효하게 bound된 source approval: 0/11.** repository의 `review-refusal.py`·`review-scope.py` 판정과 원문 첫 줄·footer 직접 검토로 확인했다. REST `commit_id`가 새 head를 가리켜도 승인 본문의 head/scope는 이전 소스에 묶여 있었다. canonical diff가 같다는 사실만으로 누락된 immutable head/scope 승인을 채우지 않는다.
- 유효한 premerge Changes Requested: 0. 실제 dismissal 시각을 merge cutoff에 적용한 결과다.
- 현재 complete thread collection은 11개 PR 모두 0개다. 별도 premerge thread snapshot이나 resolve 시각이 복구된 것은 아니므로 **병합 전에도 thread가 없었다고 주장하지 않는다.**

[공개 감사 댓글의 정확한 readback](https://github.com/jeong-sik/masc/pull/45710#issuecomment-6381863174)에 이 범위가 기록되어 있다. 로컬 근거는 `/tmp/goal-external-merged-source-accounting.json`과 `/tmp/masc-goal-original-eleven-premerge-audit-20261024/audit-report.md`이다. 이는 관측된 외부 integration과 역사적 source-admission 공백의 기록이다. 소스 동작 실패 판정, 사후 승인, 새 수리의 merge 또는 최신 main 실행 성공을 뜻하지 않는다.

새 `ac7fe109…` 이식의 외부 helper 반환 계약과 trust-harness 검증 보존은 위 준비 코드에서 확인했다. 원래 49개 커밋은 재게시하지 않으며 닫힌 원래 11개 branch에도 쓰지 않았다. 당시 이 이식의 실행 결과는 없었으며, 현재44b6 결과와 구분한다.

## 수리하는 실제 경계

작업자가 판단한 뒤 Task에 반영하거나 관측 레지스트리에 게시하는 사이에 운영자 결정, 응답 유실, 취소 또는 재시작이 생길 수 있다. 이때 같은 원본을 다시 실행하거나, 새 시각과 빈 도구 목록으로 원래 실행 증거를 덮어쓰면 판단과 실제 작업 상태가 분리된다.

이번 소스는 다음 경계를 연결한다.

1. 실제 `Task.InvalidState`만 typed `Authority_refused`로 전달한다. 오류 문자열은 진단 정보이며 분기 권한이 아니다. 다른 Workspace 오류는 실제 타입을 보존한다. 명시적 거부 뒤에는 관측만 한 번 수행하며 두 번째 apply를 하지 않는다. 자신의 정확한 after-state는 `Finished`, 제3 상태는 원래 commit과 관측 JSON을 함께 가진 `Conflicted`로 남긴다.
2. 같은 원본 digest·판단·notes를 재검증하고 호스트가 retained intent 전체를 해석한다. 충돌한 실제 Task의 id와 상태를 검증한 뒤에만 `Done` 또는 `Cancelled`를 `Superseded_by`로 분류한다. 부재·읽기 실패·비종료 상태는 이 조용한 종료 권한이 아니다.
3. 실제 reviewer 판단과 `Observer Registration` intent를 기존 Owner 이벤트 두 개로 묶어 한 번의 물리 저장으로 게시한다. Registration에는 평가 결과, 원래 시각·runtime·도구·elapsed와 판단 전에 관측한 정확한 Awaiting Task 상태를 함께 고정한다. 이 평가 행은 아직 Task commit 성공을 뜻하지 않는다.
4. 캡처된 Task 상태는 한 엄격한 codec에서 원본 verification id·producer와 canonical raw metadata를 검증한다. `Judged` 복구는 이 고정된 상태만 사용한다. 현재 terminal Task, 요청 생성 시각 또는 복구 시각으로 원래 started_at을 재구성하지 않는다. 기존 commit.before와도 완전히 일치해야 한다.
5. terminal publication은 고정된 평가 행의 결과만 실제 terminal 관측으로 바꾼다. canonical Run Registry transaction이 전체 원본 identity·started_at·completion을 비교해 durable publication을 확인한 뒤 Registration ACK, Completion ACK 순서로 기록한다. `mark_completed`의 unit 반환이나 메모리 조회를 ACK로 사용하지 않는다.
6. `Finished`와 `Conflicted`는 정확한 Completion ACK까지 복구 대상이다. 부팅 복구는 현재 Task 조회보다 먼저 원래 journal을 읽으며 Task 삭제나 표시 retention으로 인한 행 퇴출에도 원래 pending payload를 사용한다. 실제 `R.replay`의 로그 압축을 허용하고 원래 행·ACK·퇴출 후 비재생성이라는 의미를 검증한다.
7. 저장은 됐지만 응답이 유실되어 `Unconfirmed`가 반환된 경우, 정상적인 typed worker error와 판단 이후 예외·취소 경로도 canonical Owner를 다시 읽는다. 원래 publication이 남았거나 읽기 결과를 확정할 수 없으면 경쟁하는 Raised/Cancelled 행으로 덮어쓰지 않는다. ACK된 원본도 admission inventory에서 인식하므로 오래된 Awaiting 입력이 새 Running 행이나 새 모델 호출을 만들지 않는다.
8. 원래 실행 증거 또는 captured-before가 없는 기록은 명시적인 publication unavailable로 남고 domain mutation 전에 거부한다. 도구·elapsed를 꾸며 복구하지 않는다. 유효한 inventory 안에서 한 원본의 publication 오류는 별개 정상 원본의 ACK를 막지 않는다.

새 mutable 상태 레지스트리, 문자열 기반 상태 추정, 재적용 권한 또는 별도의 판단 권한은 추가하지 않는다. legacy Task worker를 활성 completion-authority 경로의 증거로 바꾸어 부르지도 않는다.

## fixture 범위와 실제 실행

아래는 ac7 준비 commit에서 실제 test_case 선언을 읽고, 새 d587 candidate에서 선언 수를 바꾸지 않았음을 확인한 수치다. 작성 당시에는 미실행이었으며 현재 44b6의 실제 5개 suite 결과는 위 artifact readback으로 확정했다. 아래 선언 수는 위 실제 결과와 대조했고 서로 같은 사실로 혼용하지 않는다. 한 test case 안의 Done/Cancelled/Rejected 하위 시나리오를 별도 통과 수로 더하지 않는다.

| suite | 선언 수 / 현재 증거 상태 | 확인할 경계 |
| --- | --- | --- |
| `test_goal_verifier_worker` | 16 declared / 실제 16 PASS | retained Goal 원본·도구·거부·commit·publication 복구 보존 |
| `test_goal_verification_agent` | 39 declared / 실제 39 PASS | 원본 admission, reviewer 진입, successor, 사람 확인 경계 |
| `test_verifier_review_worker` | 18 declared / 실제 18 PASS | 기존 11개와 새 7개 Task composition 사례 |
| `test_completion_trust_harness` | 9 declared / 실제 9 PASS | 실제 활성 Task producer→authority→registry/Board 경로 보존 |
| `test_verification_run_registry` | 23 declared / 실제 23 PASS | 기존 18개와 새 5개 strict publication·durability 사례 |

새 Worker 사례는 다음 실제 경로를 사용한다.

- 실제 reviewer가 만든 Judged 원본 뒤 운영자가 Done 또는 Cancelled로 바꾼 Task를 새 호스트가 복구한다. 운영자 상태를 보존하고 Superseded publication과 ACK를 기록한다. 미지 metadata와 빈 terminal 주체는 거부한다.
- 실제 before 관측과 apply 사이에 운영자가 Done/Cancelled/Rejected로 바꾼다. 실제 Workspace의 typed InvalidState, apply 한 번, 관측 두 번, retained conflict의 재조회·재적용 없는 재개를 확인한다. Rejected로 인한 비종료 상태는 조용한 terminal authority가 아니다.
- canonical Owner writer가 실제로 저장한 뒤 Error를 돌려준다. 같은 Worker runner가 typed persistence error를 반환하고 판단+Registration은 한 번의 실제 최종 쓰기로 함께 남는다. 실제 Caa 공유 guard가 경쟁 completion을 막고 새 호스트가 같은 원본으로 ACK한다.
- 실제 durable registry 확인 뒤 observer 취소를 발생시킨다. 표시 retention에서 즉시 퇴출된 target과 실제 Task 삭제를 거친 뒤, 새로운 Store와 실제 `R.replay`를 통해 production terminal discovery가 원래 pending payload를 복구한다. 원래 clocks/runtime/tools/elapsed를 유지하고 ACK 뒤에는 압축·퇴출된 행을 재생성하지 않는다.
- 원자적 판단 저장 직후 취소를 발생시켜 실제 공유 cancellation guard와 새 호스트 복구를 확인한다.
- 고의로 실행 증거가 없는 첫 번째 원본을 음성 대조군으로 두고 별개의 정상 원본이 durable ACK까지 진행하는지 확인한다. 대조군을 실제 Task 실행 증거로 주장하지 않는다.
- 관측 사실이 없는 원본은 Task를 바꾸기 전에 거부하고 같은 reviewer를 재실행하지 않는지 확인한다.

Registry의 새 5개 사례는 absent/running/exact completed publication, 실제 reopen 뒤 중복 쓰기 없음, 원본·결과가 다른 행의 거부, volatile/uninitialized/occupied 저장소 거부, 엄격한 terminal payload와 표시 retention 밖의 durable confirmation을 확인한다. 실제 replay 압축을 억제하거나 압축 전후 바이트 동일성을 요구해 의미 검증을 대체하지 않는다.

실행은 새 정확한 코드 head에서 명시적인 위 5개 suite를 대상으로 요청한다. run이 완료된 유용한 경계에서 artifact의 checkout SHA, suite별 실제 사례 수와 PASS/FAIL/SKIP, 실패 assertion, 로그 및 archive 해시를 읽는다. 디스패치 접수나 parser 통과를 실행 성공으로 기록하지 않는다.

## 역사적 Goal 실행 증거 — 새 수리 실행과 구분

[run 40068481261](https://github.com/jeong-sik/masc/actions/runs/40068481261)은 정확한 `cd155caed941a501fb2d068c6fe598ac48ad26d2`에서 Goal Worker 16개, Goal agent 39개, 합계 **55 PASS / 0 FAIL / 0 SKIP**를 실제 실행했다. Task suite를 반복한 실행은 아니다. [당시 실제 증거 댓글](https://github.com/jeong-sik/masc/pull/45710#issuecomment-6380761860)에 checkout과 authoritative suite-runner artifact를 읽은 범위가 남아 있다.

- artifact ZIP SHA256: `67b4d2c8579dc88d0228ead62f403e98700c8b8787e09ed25d513f8b117ba3da`.
- `ci-run-tests.log`: 98,883 bytes, SHA256 `ea069f0c91e624ef65f598c5c9994b8cddce27762327be87b576a722c2f9dd9a`.
- 실제 확인 범위에는 empty/whitespace raw receipt의 Deferred 처리와 명시 요청, retention·ACK·reopen, caught Internal과 실제 escaped observer 예외 및 실제 도구 보존, 같은 original admission, 한 번의 mock clock advance 뒤 successor와 reviewer 진입, 사람 확인 경계가 포함된다.
- private Workspace, controlled reviewer/error transport, mock clock을 사용한 production 경로 검증이다. 실제 외부 모델, 설치된 서버/Keeper, 전체 회귀 또는 배포 결과가 아니다.

이 55 PASS를 `6a2241…` 또는 나중의 새 코드 SHA에서 실행한 결과로 바꾸어 쓰지 않는다. 다른 dispatch의 run `40068460566`도 이 요청이 제출하거나 감사한 실행으로 세지 않는다. 이전 [실패 run 40064678042](https://github.com/jeong-sik/masc/actions/runs/40064678042)와 [실패 run 40065105252](https://github.com/jeong-sik/masc/actions/runs/40065105252)는 원래 실패 기록으로 유지한다.

## 비차단 제한

Completion ACK가 있는 비종료 `Conflicted`도 원래 `Commit_failed`를 유지한다. 오래된 요청이 다시 들어오면 소스 경로상 WARN과 알림 함수 호출은 반복될 수 있다. Board는 같은 subject/gate/disposition을 최근 200개 verification System post에서 찾으면 게시를 억제하므로, 매번 새 Board 글이 생긴다는 뜻은 아니다. 조회 창 밖이거나 이전 게시가 없으면 다시 게시할 수 있다. 이 범위에서 새 process enum이나 Board 동작은 바꾸지 않는다.

소스는 이 중복 요청에 모델·apply·registry 쓰기 재실행을 허용하지 않으며 통과한 fixture에서 이를 확인했다. 비종료 실패를 실제 Task 완료나 Done/Cancelled authority로 위장하지 않는다. Completion ACK는 registry publication의 확인이며 Board 전달 확인과도 구분한다.

반환된 Unconfirmed와 취소 검증은 실제 Worker/Owner와 실제 Caa 공유 guard를 연결해 수행하는 fixture다. `Eval_calibration.record_verdict`의 일반 예외를 전체 `process_task_once` 안에서 직접 주입한 별도 사례는 없다. 소스의 동일 guard 경로 검토와 이 실행 fixture의 범위를 구분한다. OS 프로세스를 강제 종료한 운영 장애 실험으로도 부르지 않는다.

## 남은 증거 경계

- 새 코드 PR #45769 / 문서 전용 상위 PR #45770 / Native Stack #45771: 위 게시 범위에 기록했다. 최종 Ready REST vector는 별도 receipt에 고정한다.
- 새 코드 commit / 직접 parent / branch main 기준 / 4파일 수리 패치와 17파일 source hash: 위에 기록했다. 최종 REST base·canonical full diff binding은 별도 receipt로 남긴다.
- 이전 6c9 compile 실패/5suite 미시작과 새 44b6의 실제 105 PASS는 위에 구분해 보존했다.
- code44b6 source approval과 본인 P2 CR 대체는 위에서 확인했다. 최종 upper source approval, current whole-stack guard 및 thread 상태는 별도 최신 판정 대상이다.
- 원래 외부 병합 Goal11 감사: 확정. 위 ac7 고정 main에 merge 11/11 포함, 07:52:35–46 UTC `jeong-sik`, premerge 유효 source approval 0/11, effective CR 0, current threads 0. 역사적 thread 부재는 미확인. [공개 readback](https://github.com/jeong-sik/masc/pull/45710#issuecomment-6381863174).
- 새 수리의 integration, 설치 binary, 실행 중 runtime, 배포 및 실제 사용자 QA: 미기록. 원래 Goal11의 관측된 외부 integration은 위 감사와 구분한다.
