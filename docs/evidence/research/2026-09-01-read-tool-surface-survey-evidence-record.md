# 읽기 도구 표면 조사 근거 기록

## 공통 헤더

- 날짜: 2026-09-01T23:50:00+09:00
- 작성자: claude (vincent 세션)
- 결정 ID: read-tool-surface-survey-2026-09-01
- 적용 대상: `config/tools/keeper_artifact_read.toml` 설명 문구,
  `test/test_keeper_runtime_schemas_toml_parity.ml` pin
- 결정 상태: 수정 PR Draft, 배포 후 재측정 대기

## 근거

| 항목 | 출처 | 확인일시 | 신뢰도 | 제한조건 | Delta |
|---|---|---|---|---|---|
| 배포 후 65분 창에서 artifact_read 54호출이 blob 8개 (최대 20호출/blob, max_bytes=500 순차 페이징) | `<base-path>/.masc/tool_calls/2026-09/01.jsonl` 배포 경계(22:14:49) 이후 구간 | 2026-09-01T23:20+09:00 | High | 65분 표본, keeper 1개(code-reviewer)가 52호출 | 남은 fanout의 주범 판정 |
| 기본 max_bytes = 최대 = 65536, 페이지가 JSON 봉투 64KiB에 맞게 이진 탐색으로 채워짐 | `config/tools/keeper_artifact_read.toml`, `lib/keeper/keeper_artifact_read.ml` (`page_of_slice_within_output_budget`) 정독 | 2026-09-01 | High | — | 500바이트 페이징이 코드 강제가 아니라 설명 유도임을 확정 |
| 모델이 만나는 blob 중앙값 2,862바이트 (히스토리 강등이 크기 무관하게 blob화) | `lib/keeper/keeper_model_input_demotion.mli` 문서 주석 (2026-08-05 라이브 체크포인트 실측 인용) | 2026-09-01 | Medium | 인용 수치이지 이번 재측정값 아님 | — |
| 스키마 발행처는 embedded TOML, 설명 pin은 parity 테스트 1곳뿐 | `lib/keeper/keeper_runtime_schemas_toml.ml:35`, `rg "continue with the returned"` 전수 | 2026-09-01 | High | — | 수정 표면 2파일로 확정 |
| Claude Code: 기본 통째 읽기(256KB/25K 토큰), 초과는 truncation 아닌 에러 (#21841 실측), unchanged-dedup 응답 | 로컬 사본 261739a — `src/tools/FileReadTool/{prompt.ts,limits.ts,FileReadTool.ts}`, `src/utils/readFileInRange.ts` | 2026-09-01 | Medium | 재구성 트리 — 릴리즈와 라인 번호가 다를 수 있음 | — |
| Codex: skills.read가 봉투 예산 이진 탐색 + next_cursor, 독트린 "부분 읽기 말고 완독" | 클론 2b7c279 — `codex-rs/ext/skills/src/tools/read.rs:294-330`, `catalog_prompt.rs:11,20` | 2026-09-01 | High | — | — |
| pi: 기본=최대(2000줄/50KB), 잘림 시 총량+다음 offset 문장, partialRate 자체 측정 | 클론 a63fb12 — `packages/coding-agent/src/core/tools/{read.ts,truncate.ts}`, `scripts/read-tool-stats.mjs` | 2026-09-01 | High | — | — |
| Hermes: 기본=최대, 구조화 next_offset + hint, 반복 읽기 4회 차단, PTC | 클론 5a8e8a6 — `tools/file_tools.py`, `tools/file_operations.py`, `tools/code_execution_tool.py` | 2026-09-01 | High | — | — |
| OpenClaw: pi read 재수출, 시스템 프롬프트 통째 교체로 읽기 신호가 도구 설명뿐, 자체 exec는 무마커 tail-trim | 클론 b4e2e74 — `src/agents/pi-tools.read.ts`, `src/agents/pi-embedded-runner/system-prompt.ts:76-81`, `bash-process-registry.ts:217-221` | 2026-09-01 | Medium | 런타임 pi 패키지는 전역 설치 0.52.7로 확인 (repo pin은 0.50.7) | — |
| Orca: 커서 프로토콜, limited/truncated 구분 | 클론 dff2ff0e — `src/cli/terminal-format.ts:162-182`, `src/main/runtime/terminal-tail-limits.ts` | 2026-09-01 | High | 파일 읽기가 아닌 터미널 스트림 — 직접 비교 대상 아님 | — |

## 검증

- TOML 새 설명이 parity pin과 바이트 동일함을 tomllib 파싱으로 확인
  (백슬래시 줄 연속 포함).
- 스키마 pin JSON이 여전히 유효한 JSON임을 확인.
- 빌드/테스트는 CI dispatch로 검증 (로컬 dune 금지).

## 불확실성

- 미확인: 설명 문구만으로 500바이트 페이징이 사라지는 효과 크기 — 모델별
  순응률이 다를 것. 추가 확인: 배포 후 blob당 호출 수 재측정.
- 미확인: code-reviewer가 max_bytes=500을 고른 정확한 출처(마커 preview 길이는
  아님 — preview 상한은 별도 상수). 설명이 완독을 가르치면 출처와 무관하게
  무의미해진다고 판단.
- 미확인: OpenClaw pinned 버전(0.50.7)의 설명 문구 — 0.49.3에는 "continue with
  offset until complete" 문장이 없고 0.52.7에는 있다. 조사 결론에는 영향 없음.

## 적용 범위

- 이번 변경: 도구 설명 문구 + parity pin. 실행기·응답 필드·bounds는 무변경.
- 배포 필요: 도구 정의는 바이너리 embedded — 재빌드·재배포 후에만 라이브.
- 후속 후보는 r1 문서에 기록 (반복 읽기 차단, 측정기 method 서브툴 보정).
