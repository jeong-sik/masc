# Skills system research and first statistics unit

## 공통 헤더

- 날짜(ISO8601): 2026-11-01T01:56:21.032891+00:00
- 작성자: Codex
- 결정 ID: skills-observability-20261101
- 적용 대상: MASC Skills API, TUI, Dashboard; issue #47033
- 결정 상태: 추적 필요

## 근거 (Evidence)

- 항목: 기존 제품의 장점과 현재 Skills 관측 계약의 결함
- 출처: [공식 자료 비교](../../research/2026-11-01-skills-authoring-and-observation.md), baseline 6182e8a5dc822c3ccdd9b8bdda89665d27d0536e 소스, issue https://github.com/jeong-sik/masc/issues/47033
- 확인일시: 2026-11-01T01:49:43Z
- 신뢰도: High
- 제한조건: 제품 문서는 현재 공식 설명이며 MASC 구현·운영 완료의 증거가 아니다. 기준 소스에 대한 독립 검토는 0/1 coverage, obsolete reader, async usage 누락, 실패 message 누락을 확인했다.
- Delta: 기록된 실행 수와 latest 존재 여부를 구분하는 v8 계약, 관측 표본 분포와 결과 기록 시각 범위를 구현 중이다.

## 검증 (Verification)

- 1차: producer → partition → statistics → server → Dashboard/TUI decoder와 표시를 추적했다. 현재 writer는 run partition만 사용한다. 예전 단일 파일 reader를 제거하며 실제 runtime 파일은 지우지 않았다.
- 2차: Dashboard의 API·Skills 화면·권한·통계 관련 4개 파일, 98개 테스트 통과. `pnpm exec tsc --noEmit --pretty false`, 변경 TypeScript 파일의 ESLint 통과. 로그는 작업 worktree `artifacts/skills-observability-20261101/`에 보존했다.
- 3차: 변경 OCaml 11개 파일의 `ocamlc -stop-after parsing` 및 `git diff --check` 통과. 로컬 Dune build는 하지 않았다. OCaml 타입·동작 CI와 변경 후보의 실제 TUI/Dashboard 표시 검증은 미완료다.
- 재현 결과: 원래 실행 ID 중복 제거, deferred 분리, 실제 0과 미관측 null 구분, 기록 시각 범위와 nearest-rank 표본 통계를 검사하도록 기능 시나리오를 확장했다. OCaml 테스트의 실행 성공은 아직 주장하지 않는다.

## 불확실성 (Uncertainty)

- 미확인 항목: 후보 OCaml 동작 검사, 후보 화면 캡처, 실제 배포, 생성·조합 UX 개선 및 async usage/실패 message 후속 변경.
- 영향: 첫 통계 변경 또는 Dashboard 테스트 성공만으로 전체 사용자 목표를 완료할 수 없다.
- 추가 확인 필요: issue #47033의 전체 요구와 연구 문서의 완료 증거 표를 유지하며 후속 작업을 계속한다.

## 적용범위 (Scope)

- 영향 받는 영역: fresh skill-evidence/v8 계약과 두 소비자, retained-run 계산, 오래된 reader 제거.
- 제약/배제: 새 workflow engine, 숫자 임계값 제어, 통계 기반 실행 Gate, 저장된 기록 migration, 기존 runtime 파일 삭제를 추가하지 않는다. 보존 결과의 관측은 전체 과거 실행 관측이나 업무 성공을 증명하지 않는다.
- 롤백 조건: 현재 head의 실제 타입·기능 검사에서 결함이 확인되면 공개 계약과 두 소비자를 함께 고친다. 이전 wire schema를 조용히 받아들이는 호환 reader는 추가하지 않는다.

## 첫 후보 검사 및 후속 관측 수정

- 출처: https://github.com/jeong-sik/masc/pull/47036, https://github.com/jeong-sik/masc/actions/runs/41263263036, 작업 worktree의 dashboard-tests-unit2.log 및 eslint-unit2.log
- 확인일시: 2026-11-01T02:09:02.893001+00:00
- 신뢰도: High
- 첫 후보: 7a53f1d16d80576ca3e293699f7687f11d8c1c76, branch feat/skills-observability-20261101, Test workflow, TARGET_SUITES=test_keeper_skill_composition_evidence,test_tui_decode,test_dashboard_http_core, minimal=true, completed/success. 5 + 376 + 171 = 552개 테스트 통과. 현재 head의 독립 소스 검토도 PASS이며 GitHub 공식 승인과는 별개다.
- 후속 변경: 목록의 delivered는 결과를 받은 원래 invocation 수다. 원래 턴과 비동기 전달 경계가 둘 다 있어도 같은 invocation을 한 번만 센다. 후속 actions는 canonical activation summary의 중복 제거를 그대로 사용한다. 마지막 activation은 RFC3339 문자열 순서 대신 실제 시각을 비교한다.
- 표시 수정: 최상위 실패의 message, failure_class, effect_disposition을 두 화면에 표시한다. 노드 실행은 완료됐으나 결과 게시가 실패한 사례의 실제 실패 사유와 완료된 노드 증거가 함께 남는다.
- 후속 검증: Dashboard 4개 파일 99개 검사, TypeScript typecheck 및 touched-file ESLint 통과. 실제 비동기 전달·후속 도구 시나리오의 검사도 확장했으며 그 OCaml 실행은 아직 미확인이다.
- 한계: 이 결과는 설치나 운영 화면 검증이 아니다. 생성·조합 UX와 실행 탐색, 실제 후보 화면 검증 등 전체 #47033 요구는 계속 진행 중이다.


## 사용량 수정 검사와 생성 화면 후보

- 출처: https://github.com/jeong-sik/masc/actions/runs/41265109694, https://github.com/jeong-sik/masc/pull/47041, 현재 worktree의 dashboard-tests-unit3.log, typecheck-unit3.log, pyright-unit3.json 및 pyright-baseline.json
- 확인일시: 2026-11-01T02:43:49Z
- 신뢰도: High
- 사용량 후보: ffd3500f7ed203343b857c5dcdf4a2ab58d74bf8, branch feat/skills-usage-evidence-20261101, Test workflow, TARGET_SUITES=test_keeper_skill_activation_ledger,test_keeper_owned_jobs, minimal=true, completed/success. 40 + 84 = 124개 테스트 통과. 앞선 head 50926115e56a017cbaa8ce258e03547359d9446d의 Test 41264720838은 테스트의 직접 라이브러리 선언 누락으로 실패했고, 그 선언을 추가한 뒤 같은 두 suite를 다시 실행했다.
- 생성 후보: 고정 예제 대신 직접 단계, 도구, JSON 입력 또는 typed template, 명시적 의존 관계, named output, inline/async 및 branch failure policy를 작성한다. 도구 스키마는 현재 authoring descriptors에서 읽으며, 미리보기와 생성은 기존 파서를 사용한다. 미리보기는 파일을 쓰지 않는다.
- 의도 검증: 자유 Instructions의 열린 코드 블록이 실행 선언을 삼키지 않도록 선언을 먼저 둔다. 선택한 kind를 일시적 요청 기대값으로 전달하여 기존 파싱 결과와 비교한다. Instruction에서 실행 조합을 게시하거나, Composition에서 선언 없는 문서를 게시하는 경우 쓰기 전에 거절한다. 원문을 작성하는 Keeper publication은 원문 자체가 의도를 표현하므로 기대값 None을 명시한다. kind를 저장된 별도 권위로 만들지 않는다.
- 후속 검증: Dashboard 5개 파일 107개 검사 및 TypeScript typecheck 통과. OCaml은 변경 파일의 parse-only 검사만 통과했고, 새 preview/create/HTTP/배포와 화면 실측은 아직 완료하지 않았다. 로컬 Dune build는 실행하지 않았다.
- Python caller: ruff check 통과. pyright의 17개 오류는 수정 전 HEAD 파일과 오류 메시지가 모두 같았고, formatter 미통과도 기준 파일에 재현됐다. 이번 변경은 create 요청의 kind 한 필드다. 관련 기준 결함은 https://github.com/jeong-sik/masc/issues/47072 에 기록했다.
- 한계: 독립 소스 검토와 기능 검사, 공식 GitHub 승인, 병합, 설치 및 실제 UI 동작은 각각 별도 증거다. 전체 #47033 요구는 계속 진행 중이다.
