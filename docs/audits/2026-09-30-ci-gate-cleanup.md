# CI 검사 검수 — 2026-09-30

범위: `.github/workflows/*.yml` 전체 실행 진입점, 통합 lint 드라이버의 모든 검사 호출, 삭제 검사에 연결된 테스트·기준값·Makefile 참조. 전체 제품 테스트 1,670개 각각의 의미를 전수 검증했다는 주장은 하지 않는다.

판단 기준: 구체적인 빌드·설치·요청·데이터 손상과 연결된 검사는 유지한다. 설명 길이·파일 개수·주석 문구·줄번호·CSS 표기·빈 커밋·검사 강제 연결을 제품 실패로 취급하는 검사는 삭제한다. 검사 스크립트 19개와 기준값 파일 9개를 삭제했다. 이름에 ratchet/gate가 있다는 이유만으로 삭제하지 않는다.

## 삭제한 검사

| 경로 | 삭제 근거 |
|---|---|
| `scripts/lint/timeout-env-ceiling.sh` | 환경변수 이름 개수 상한 |
| `scripts/lint-timeout-env-count.sh` | Dashboard getter 개수 15 상한 |
| `scripts/dashboard-drift-check.sh` | CSS 클래스 표기 개수 상한 |
| `scripts/lint/no-raw-font-size-px.sh` | CSS 표기 강제 |
| `scripts/tla-ppx-ratchet.sh` | PPX 파일 및 주석 개수 하한 |
| `scripts/tla-bug-model-ratchet.sh` | 모델 파일 개수 하한 |
| `scripts/ci/check-guards-are-wired.py` | 모든 검사 스크립트를 CI에 추가하도록 강제 |
| `scripts/check-issue-taxonomy-truth.sh` | 문서에 taxonomy 문자열 복제 강제 |
| `scripts/check-pr-hygiene.sh` | 빈 커밋과 patch 중복으로 기능 변경 차단 |
| `scripts/check-release-train-guard.sh` | 현재 태그 상태와 major 정책으로 정상 버전 변경 차단 |
| `scripts/audit-ocaml-phase-count.sh` | 주석 속 phase 숫자와 표현 비교 |
| `scripts/audit-tla-phase-count.sh` | 모델 주석 속 phase 숫자와 표현 비교 |
| `scripts/audit-tla-ml-line-refs.sh` | 문서 줄번호 및 허용 오차 강제 |
| `scripts/audit-ocaml-spec-nav-line-refs.sh` | 주석 줄번호 및 허용 오차 강제 |
| `scripts/lint-magic-number.sh` | 숫자 반복 횟수 advisory 소음 |
| `scripts/lint/exhaustive-guard.sh` | 와일드카드 반환 표기 advisory 소음 |
| `scripts/ci/check-ignore-without-comment-diff.sh` | ignore 호출에 특정 정당화 주석 강제 |
| `run-lint-suite.sh`: Base policy | import/shadow 개수 증가는 기능 실패가 아님. 건강 보고용 도구는 남김 |
| `check-ssot.sh`: R6-home-masc-root-docs | 역사적 문서의 경로 언급 개수를 58로 제한. 실제 코드 경로 검사는 유지 |
| `check-doc-truth.sh`: prose/translation/prefix | 특정 한국어·영어 문장, heading·table 개수, invariant prefix 목록 고정 삭제. 버전·설치 pin·존재하지 않는 로컬 참조 검사는 유지 |
| `test_keeper_tool_schema_bytes` | 스키마 총 바이트 상한과 여유분 하한 삭제 |
| `test_tools_coverage`: description length | 설명문 20~1080 글자 상한·하한 삭제 |
| `test_execute_tool_toml_parity`: description | 800바이트 상한 및 세 문구 고정 삭제. argv/command 입력 구조 검사는 유지 |
| `test_keeper_tool_surface_schema`: golden | 정확한 tool 이름 집합 고정 삭제. provider가 거절하는 items 없는 배열 검사는 유지 |
| `test_keeper_tool_definition_source`: first line | summary 잘림 여부로 모든 도구 문장 수정을 차단하는 검사 삭제. 출처 해소 검사는 유지 |
| `scripts/check-execute-async-surface.sh` | Execute 런북·설명·테스트 함수 이름 고정; 입력 구조 검사가 이미 별도로 존재 |
| `scripts/check-boundary-guard-mli-pairs.sh` | 새 .mli에 내용 위반이 없어도 grep scanner allowlist 유지 요구 |

## 워크플로 전체 진입점

| 워크플로 | jobs | 검수 결정 |
|---|---|---|
| `antigravity-context.yml` | zero-prompt-pty | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `bench-tests.yml` | pytest, compare-tui, server-harness-tests, compare-server, compare-checkpoint-history | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `browser-host-proof.yml` | macos-native-host | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `browser-stagehand-proof.yml` | macos-stagehand | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `ci.yml` | build | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `dashboard-artifact.yml` | bundle | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `installer-shell-path.yml` | fresh-terminal | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `issue-taxonomy.yml` | apply | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `kata-volume-smoke.yml` | kata-volume | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `lane-addon-images.yml` | packages, image | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `lane-addon-native.yml` | macos | 기능 실행 유지; schema bytes 검사 참조를 provider schema 검사로 변경 |
| `lane-dos-package.yml` | actual-dos | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `linux-portable-python.yml` | interpreter | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `linux-x64-probe.yml` | linux-x64-probe, stagehand-model-probe | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `model-release-evidence.yml` | observe | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `pr-check.yml` | tla, lint, check, release-check, dashboard-types, required-success | 기능 검사 유지; arbitrary scanner advisory step 삭제 |
| `process-groups.yml` | process-groups | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `release-candidate.yml` | compile, behavior, installation, evidence | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `release.yml` | validate-release-entrypoint, build, release-body, release | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `sandbox-image.yml` | image | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |
| `test.yml` | test | 유지: 빌드·기능·설치·아티팩트·운영 자동화 실행 |

## 통합 lint 호출 전수 목록

각 행은 이전 드라이버의 호출 단위다. 남긴 source 검사는 구체적인 wire/취소/데이터/설치/테스트 누락 또는 계약 검사로 남겼으며, 컴파일러 typed artifact를 사용하는 OCaml boundary 검사는 단순 grep 카운트와 구분했다. 실제 실행 결과는 별도 검증이며 목록 자체가 기능 증명은 아니다.

| 호출 | 결정 |
|---|---|
| ${label} | 유지 |
| PR check Draft/Ready approval contract | 유지 |
| Review queue ledger readiness | 유지 |
| Review approval and merge boundary | 유지 |
| Combined-tree batch review evidence | 유지 |
| Installer terminal wizard | 유지 |
| Installer upgrade configuration | 유지 |
| Stagehand probe offline controls | 유지 |
| Stagehand extension installer | 유지 |
| Deployment scripts refuse before touching prod | 유지 |
| Issue taxonomy truth | 삭제 |
| CHANGELOG has one section for this version | 유지 |
| Changelog section self-test | 유지 |
| Changelog fragments well-formed | 유지 |
| Changelog fragments self-test | 유지 |
| Logging consistency | 유지 |
| Issue taxonomy parser and reconciliation | 유지 |
| OCaml test suite reporter self-test | 유지 |
| Edited-tests selector self-test | 유지 |
| Prompt source words self-test | 유지 |
| Prompt source words agree | 유지 |
| Keeper host_cwd leak gate | 유지 |
| Turn-path provider-agnostic self-test | 유지 |
| Turn-path provider-agnostic gate | 유지 |
| Dashboard tests type-checked self-test | 유지 |
| Dashboard tests type-checked | 유지 |
| Test suites declared as tests self-test | 유지 |
| Test suites declared as tests | 유지 |
| Test modules are wired self-test | 유지 |
| Test modules are wired | 유지 |
| Test functions are registered self-test | 유지 |
| Test functions are registered | 유지 |
| Dune suite scope self-test (RFC-0428) | 유지 |
| Referencing suites self-test (RFC-0428) | 유지 |
| Test stanza env reader self-test | 유지 |
| Test stanza env is readable | 유지 |
| Hardcoded model prefix | 유지 |
| Raw font-size px | 삭제 |
| Harness connector env ratchet (#28807) | 유지 |
| OCaml comment terminator trap | 유지 |
| Wire-field removal schema gate (#29516/#29601/#29666) | 유지 |
| Timeout env knob ceiling (RFC-0138) | 삭제 |
| .mli env knob exists self-test | 유지 |
| .mli env knob exists | 유지 |
| Guard scan targets exist self-test | 유지 |
| Guard scan targets exist | 유지 |
| Shim stub set agrees self-test | 유지 |
| Shim stub set agrees | 유지 |
| Opam cache freshness ratchet | 유지 |
| Opam cache freshness self-test | 유지 |
| No actionable-signal bool context | 유지 |
| Provider name hardcoding ratchet | 유지 |
| Keeper behavior hardcoding | 유지 |
| Eval tool-selector runtime import | 유지 |
| One process manager in lib | 유지 |
| Legacy tool surface name | 유지 |
| Retired tool husk ratchet | 유지 |
| Synthetic tool-call residue ratchet | 유지 |
| Tool substrate adapter surface | 유지 |
| Tool -> Keeper dependency-direction ratchet (RFC-0194) | 유지 |
| MASC domain ownership ratchet | 유지 |
| Keeper turn content boundary self-test | 유지 |
| No Tool_result.error + Printexc (RFC-0148) | 유지 |
| Board attention exact-flow boundary self-test | 유지 |
| Boundary redaction SSOT (RFC-0132 PR-3) | 유지 |
| No fabricated telemetry | 유지 |
| No inline ok-envelope literals | 유지 |
| Tool-subject key lists mirror each other | 유지 |
| No inline error-envelope literals | 유지 |
| No inline json_kind_name | 유지 |
| No yojson 3.0 dead arms | 유지 |
| Workflow YAML syntax | 유지 |
| Pinned Ubuntu runner labels | 유지 |
| Pinned Ubuntu runner labels self-test | 유지 |
| Workflow skip propagation self-test | 유지 |
| Workflow skip propagation | 유지 |
| PTY wait guard self-test | 유지 |
| PTY waits read the terminal | 유지 |
| Board SLO extractor fixture | 유지 |
| TUI graceful restart fixture | 유지 |
| TUI graceful restart, one real cycle | 유지 |
| Feedback-loop metrics fixture | 유지 |
| Stale-worktree cleanup keeps commits | 유지 |
| Agent-core package shape | 유지 |
| Execute async surface | 삭제 |
| HITL exact-flow boundary | 유지 |
| Turn-records envelope parity | 유지 |
| Drain loops yield | 유지 |
| H2 body close goes through the helper | 유지 |
| Log severity anti-patterns | 유지 |
| Determinism contract | 유지 |
| TLA variant sync | 유지 |
| SSOT spawn drift | 유지 |
| Silent failure patterns | 유지 |
| Spec Mirrors: references resolve | 유지 |
| docs/spec names files that exist | 유지 |
| RFC frontmatter consistency | 유지 |
| Env-read config floor self-test | 유지 |
| Exact-field decoders have a preflight | 유지 |
| Path layout SSOT | 유지 |
| odoc references resolve | 유지 |
| TLA bug models keep their pair | 삭제 |
| OCaml code-only counter self-test | 유지 |
| TLA ppx coverage floor | 삭제 |
| TLA cfg has a parent spec | 유지 |
| TLA annotation drift | 유지 |
| Model prefix inheritance | 유지 |
| Every check script is reached | 삭제 |
| Fun.protect finalizer guard | 유지 |
| ignore justification self-test | 유지 |
| Dashboard backend-coupled test detector self-test | 유지 |
| Node alias target reader self-test | 유지 |
| ignore justification (new sites) | 삭제 |
| Stale-base revert guard self-test (RFC-0235) | 유지 |
| Stale-base revert guard (RFC-0235) | 유지 |
| Release train guard | 삭제 |
| PR hygiene | 삭제 |
| Changelog entries arrive as fragments | 유지 |
| Boundary-guard .mli pairing | 삭제 |
| Wire-field removal schema gate | 유지 |
| Cancel guard fixtures | 유지 |
| Cancel guard on wildcard catches | 유지 |
| Wildcard-only match self-test | 유지 |
| Wildcard-only match | 유지 |
| TUI renderer writes no state | 유지 |
| Committed-credential self-test | 유지 |
| No committed credentials | 유지 |
| Eio conventions | 유지 |
| OCaml phase-count drift | 삭제 |
| TLA phase-count drift | 삭제 |
| Route tool catalog | 유지 |
| Shell IR structural boundary | 유지 |
| Base policy | 삭제 |
| Sublib leaf boundary self-test | 유지 |
| SSOT rules | 유지 |
| TOML syntax | 유지 |
| YAML syntax | 유지 |
| Sandbox dune version | 유지 |
| Sandbox OCaml version | 유지 |
| Checkpoint legacy purge | 유지 |
| Checkpoint legacy purge regression | 유지 |
| Dashboard nav-event parity | 유지 |
| TLA harness coverage | 유지 |
| Opam lock covers declared deps | 유지 |
| Keeper runtime setting registry | 유지 |
| Env snapshot default drift | 유지 |
| Hardcoding and truth audit | 유지 |
| Boundary guard | 유지 |
| Dashboard env knob count | 삭제 |
| Silent failure | 유지 |
| Dashboard styling drift | 삭제 |
| Dashboard prompt keys | 유지 |
| TLA spec line-refs | 삭제 |
| OCaml spec-nav line-refs | 삭제 |
| Magic number repetition (advisory) | 삭제 |
| Fragile-match (advisory, RFC-0071 Phase 1) | 삭제 |

## 검증 범위

- 셸 문법, YAML 파싱, 변경한 Python 구문 및 diff whitespace 확인.
- Dune test 모듈·스크립트 연결 검사와 test 함수 등록 검사.
- 버전·설치 문서 검증과 SSOT 검사 통과. isolated checkout doc/version fixture 4개 통과.
- 커밋된 격리 체크아웃에서 edited-test selector self-test 전체 통과. 커밋 전 삭제된 tracked 파일을 읽던 진단 실패는 실제 CI checkout에서는 재현되지 않음.
- 로컬 Dune 빌드를 하지 않는다. remote CI 결과를 받기 전 compile/runtime 통과를 주장하지 않는다.
