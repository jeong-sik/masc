# keeper 도구 왕복 낭비 근거 기록

## 공통 헤더

- 날짜: 2026-09-01T20:00:00+09:00
- 작성자: claude (vincent 세션)
- 결정 ID: tool-roundtrip-waste-2026-09-01
- 적용 대상: keeper 도구 응답 설계 (`keeper_tasks_list` unchanged 응답,
  agent_core 인자 검증 에러 렌더, keeper 시스템 프롬프트 호출 계약)
- 결정 상태: 수정 PR 3건 Draft (#32322, #32326, #32327), 배포 후 재측정 대기

## 근거

| 항목 | 출처 | 확인일시 | 신뢰도 | 제한조건 | Delta |
|---|---|---|---|---|---|
| 왕복 낭비 28.1% (2,115/7,515) | `scripts/measure-tool-roundtrips.py --date 2026-09-01` | 2026-09-01T20:00+09:00 | High | 로그가 하루 안에서 계속 자람 — 절대값은 실행 시각 의존 | 신규 측정 (이전 지표 없음) |
| unchanged 재호출 쌍 211, 직전 응답 전부 success·232B | 같은 스크립트 + `tool_calls/2026-09/01.jsonl` 원본 대조 | 2026-09-01 | High | 같은 턴 내 연속 쌍만 셈 | 원인이 "모델 무시"가 아니라 "응답 자기모순"으로 판정 변경 |
| row 통계가 Unchanged에도 prepend | `lib/keeper/keeper_tool_task_runtime.ml:451-468` 정독 | 2026-09-01 | High | — | — |
| enum 위반이 허용값을 소거 | `packages/agent_core/lib/tool_input_validation.ml:237-241` 정독 | 2026-09-01 | High | — | — |
| 병렬 실행기 완비 + 프롬프트 문구 0건 | `packages/agent_core/lib/agent/agent_tool_batch_plan.ml` + wire capture system_prompt 검색 | 2026-09-01 | High | wire capture는 agent-core 레인만 | — |
| 외부 하네스 5종의 수렴 설계 | Claude Code·OpenClaw 로컬 사본, Codex·pi·Hermes·Orca shallow clone 정독 | 2026-09-01 | Medium | Claude Code 사본은 재구성 트리(라인 번호가 릴리즈와 다를 수 있음), OpenClaw의 에이전트 루프는 SDK 미설치로 미확인 | — |

## 검증

- 1차: 수기 분석(인라인 파이썬, 18:37 시점 6,738행)으로 3분류 27.5% 도출
- 2차: `scripts/measure-tool-roundtrips.py`가 같은 로직으로 같은 파일에서
  28.1% (행 수 증가분만큼 차이) — 스크립트를 SSOT로 승격
- 재현: `scripts/measure-tool-roundtrips.py --date 2026-09-01`

## 불확실성

- 미확인: #32327(프롬프트 계약)의 효과 크기 — 모델별(glm/deepseek/gpt 계열)
  순응률이 다를 것. 영향: batch_size 개선 폭 예측 불가. 추가 확인: 배포 후
  모델별 분해 측정.
- 미확인: probing 중 인프라 실패 오인 재시도(memory 140건)는 이번 수정 범위
  밖 — `keeper_tool_memory_runtime.ml`의 실패 클래스 붕괴(후속 후보)가
  남아 있어 probe 수치가 0으로는 안 내려감.
- 미확인: 외부 하네스 대조 중 Claude Code의 수치성 주석(~600토큰 listing 등)은
  코드 주석 인용이지 재측정값이 아님.

## 적용범위

- 영향 받는 영역: keeper 도구 응답 계약, agent_core 검증 에러 렌더,
  keeper 시스템 프롬프트(골든 픽스처 포함)
- 제약·배제: unchanged 경로의 backlog 읽기 스킵은 revision 계약 변경이
  필요해 배제. cursor 추가(#29101)와 실패 클래스 분리는 후속.
- 롤백 조건: 배포 후 재측정에서 unchanged-recall pairs가 유의미하게 남으면
  #32322의 진단이 틀린 것 — r2로 재조사 (완화책 적층 금지).

## r2 추가 (2026-09-02)

- Evidence: 본문 문서 `## r2` 절. raw trace 경로 3개(analyst turn-1788307692377, code-reviewer turn-1788290285533, edgar.a.poe turn-1788304511212)와 `tool_calls/2026-09/02.jsonl`.
- Timestamp: 2026-09-02T09:35:00+09:00 (배포 경계 02:17:06 KST 는 `ps -o lstart` 로 확인)
- Confidence: Medium — 462행/59턴은 하루 창의 6%. keeper 단위 판독은 High(원문 발화 인용), 수치 추세는 Low.
- Delta: r1 의 artifact paging 초과(968회/일)는 설명 문구 문제가 아니라 두 keeper 의 행동(검색 대용 탐침 #32449, 오독 탐색 #32451)이 대부분이었다. #32322·#32326 은 이 창에서 해당 경로가 안 타서 미검증. 새 항목 #32452(time_now 폴링).
