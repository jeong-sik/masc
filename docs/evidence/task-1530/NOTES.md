# task-1530 evidence — degrade_image_messages → degrade_blocks_messages migration

- task: task-1530 ([polish] priority 5, code-reviewer #35252 리뷰 권장 — c-8332c137)
- 브랜치: polish/task-1530-degrade-image-worker-migration @ a0cc231 (origin/main 최신)
- 커밋: 5538bfa — 1 file changed, +9/−38 (api_common.ml만)

## 변경 내용

`degrade_image_messages`의 inline 워커(37줄: 자체 degraded 카운터·rewrite_block·
ToolResult 내부 rewrite_inner·omissions note 연결)를 제거하고, #35252에서
신설된 공용 워커 `degrade_blocks_messages` 위의 9줄 match로 교체.

## 시맨트 등가성 (원문 대조)

| 동작 | 기존 inline | 공용 워커 |
|---|---|---|
| Image 블록, capability=false | placeholder 치환 + 카운트 | 동일 (Some(note,placeholder) → placeholder + 카운트) |
| ToolResult 내부 Image | 재작성 + note를 canonical content에 "\n" 연결(빈 content면 note만) | 동일 (notes=[] → 원블록 유지 포함) |
| capability=true | 완전 no-op(when 가드) | 동일 (rewrite_block이 None, notes=[] → 원본 유지) |
| 반환 | (messages, degraded 수) | 동일 |

mli doc 주석·시그니처 불변 → 호출처(backend_openai_request.ml:320,
backend_gemini.ml:663) 변경 없음.

## 검증 (a0cc231 트리, 이번 체크아웃 실측)

- `dune build @check` (lib 타깃): 녹색
- `dune runtest packages/agent_core/lib/llm_provider`:
  `FAILED 1 / 4 tests` — 유일한 red는
  `exact_output_plan.ml:683 "exact preflight freezes refreshed credentials
  until a new plan is prepared" is false`
- red 귀속: 수정 전 동일 커밋(a0cc231)에서 동일 1/4(직전 실측) → 이번 변경과
  무관. pickaxe(`git log -S 'freezes refreshed credentials'`)로 해당 테스트는
  #35091(6ed999e, feat(auth): refresh ADC tokens at provider HTTP boundaries)
  이 구현과 함께 추가했고, 84e37b8..a0cc231 범위에 #35091 관련 커밋이 없어
  84e37b8 클린 트리부터 존재한 main 상속 red(3478 턴 실측과 일치).
  task-1491 CI targeted run(34623835070)의 tool matrix red와도 동일 계열 서명.
- 나머지 3/4(문서·오디오·이미지 디그레이드 및 기타 inline tests) 녹색 유지.

## 남은 일

- Draft PR 발행 → task-1530 완료 제출(별도 턴)
- exact_output_plan 자격증명 동결 red는 별도 [polish] 후보(본 task 범위 밖)
