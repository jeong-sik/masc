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
