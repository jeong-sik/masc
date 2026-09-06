---
rfc: "0430"
title: "DeepSeek direct API full integration"
status: Draft
created: 2026-09-06
updated: 2026-09-06
author: vincent
related: []
---

# RFC-0430 — DeepSeek direct API full integration

## 무엇을

agent_core가 deepseek.com 직접 API를 카탈로그·런타임 양쪽에서 완전히 지원한다.
2026-09-06 계정에 $50 를 충전하고 런타임 체인 3 lane(glm-5.2/5.3/5-turbo)의
끝에 `deepseek.deepseek-v4-flash` 를 넣었다. 이 RFC 는 그 다음 — 문서 전수
분석(2026-09-06, api-docs.deepseek.com 전 페이지 + awesome-deepseek-agent)로
확정한 카탈로그/codec 갭을 닫는 작업의 범위와 순서를 정한다.

## 근거 — 문서에서 읽은 사실 (2026-09-06, 출처 명시)

- serve 모델 3종: `deepseek-v4-flash`(V4-Flash-0731), `deepseek-v4-pro`(V4-Pro-0813),
  `deepseek-v4-flash-vision-exp`(실험, 이미지 입력). 컨텍스트 1M, max output 384K.
  (https://api-docs.deepseek.com/)
- 신가(2026-08-16 16:00 UTC~), peak/off-peak 이중 — flash 입력 miss $0.44/$0.22,
  출력 $1.32/$0.66; pro 입력 miss $1.32/$0.66, 출력 $3.96/$1.98.
  cache hit 입력은 miss 의 약 1/30(flash $0.014/$0.007).
  (https://api-docs.deepseek.com/quick_start/pricing, /news/news260813)
- `tool_choice` 는 `none`/`auto`/`required`/named function 전부 지원.
  카탈로그의 `supports_required_tool_choice=false` 근거는 V3 시절
  deepseek-ai/DeepSeek-V3 #1376 (2026-06-30 확인) — V4 스펙과 어긋난다.
  (https://api-docs.deepseek.com/api/create-chat-completion)
- thinking: `{"thinking":{"type":"enabled"|"disabled"}}` + `reasoning_effort`
  `high`/`max`. **tools 가 있는 요청은 이전 모든 턴의 `reasoning_content` 를
  다시 보내야 한다 — 빠뜨리면 400.** tools 가 없으면 reasoning_content 는
  무시된다. (https://api-docs.deepseek.com/guides/thinking_mode)
- reasoning 응답 필드: `message.reasoning_content`, usage 에
  `prompt_cache_hit_tokens`/`prompt_cache_miss_tokens`/
  `completion_tokens_details.reasoning_tokens`.
- keep-alive: non-streaming 은 빈 줄, streaming 은 `: keep-alive` SSE 코멘트를
  계속 받는다. 추론 시작 전 10 분이 지나면 서버가 접속을 끊는다.
  (https://api-docs.deepseek.com/quick_start/rate_limit)
- `user_id` 파라미터: 콘텐츠 심사·KVCache·스케줄링 격리 단위.
- Responses API 정식 지원(base_url 그대로, Codex 용도; `[DONE]` 없이 종료
  이벤트 3종). Anthropic 호환(`/anthropic`, claude-* 모델명 자동 매핑,
  Claude Code 공식 연결 경로). Files API(이미지 전용, vision-exp 와 세트).
  (https://api-docs.deepseek.com/guides/responses_api, /guides/anthropic_api,
  /guides/files_api, /news/news260821)

전체 분석 원문: 세션 산출물 `/tmp/deepseek-docs-analysis.md` (repo 외).

## 고치는 것 — 갭과 순서

| # | 갭 | 위치 | 위험/가치 | Phase |
|---|---|---|---|---|
| 1 | 직접 deepseek 4행에 `reasoning_replay` 없음 | models.toml | thinking+tools 루프에서 매 턴 400 — lane 실패의 직접 원인 | P0 |
| 2 | 가격이 옛 값(flash $0.14/$0.28) — 신가 peak 반영 안 됨 | models.toml | 비용 계산·예산 판정 오류 | P0 |
| 3 | `cache_read_multiplier` 없음(hit≈miss/30) | models.toml | 캐시 히트 비용 과대평가 | P0 |
| 4 | `supports_required_tool_choice`/`supports_named_tool_choice=false` | models.toml | V4 스펙과 불일치 — 강제 tool_choice 거부. 실측 후 전환 | P0(실측 동반) |
| 5 | vision-exp 모델 행 없음 | models.toml | keeper 이미지 입력 경로 확장 | P1 |
| 6 | Anthropic 호환 provider stanza 없음 | runtime.toml | Claude Code 런타임을 deepseek 로 — 기존 anthropic codec 재사용 | P1 |
| 7 | Responses API 연결 없음 | provider/codec | `backend_openai_responses` 는 있음 — deepseek base_url 연결 검증 | P2 |
| 8 | SSE keep-alive 코멘트/빈 줄 처리, 10 분 절단 | codec | 긴 턴에서 파서 오동작 가능 — 실측으로 확인 후 필요시만 | P2 |
| 9 | Files API | agent_core | 이미지 재사용·대용량 전송 — keeper 화상 워크플로 수요 시 | P3 |
| 10 | `user_id` 송신 | codec | KVCache keeper 격리 — 측정 후 판단 | P3 |

제외: FIM completion, Chat Prefix Completion(beta) — masc 에 소비자가 없다.

## 구현 순서

- **Phase 0 (P0)**: models.toml deepseek 4행 — `reasoning_replay` 지정
  (ollama_cloud deepseek 행의 `drop_without_tool_preserve_with_tool` 선례와
  문서 회귀 규칙이 일치하는지 실측으로 확인하고 지정), 가격 갱신(peak 기준
  단일가 + off-peak 주석), `cache_read_multiplier` 추가, tool_choice 실측 후
  플래그 전환. 카탈로그는 서버 재시행 시 반영된다(오버레이 아님).
- **Phase 1 (P1)**: vision-exp 행(`supports_image_input=true`, base
  openai_chat) 추가. `[providers.deepseek_anthropic]`(kind anthropic,
  base_url `https://api.deepseek.com/anthropic`) 등록과 Claude Code 슬롯
  대응 — 모델 매핑이 서버 내장이므로 스탠자만으로 동작하는지 확인.
- **Phase 2 (P2)**: Responses API — provider stanza(request_path `/responses`)
  로 `backend_openai_responses` 가 그대로 소화하는지 파리티 테스트. SSE
  keep-alive 는 실측 로그로 필요성 판정.
- **Phase 3 (P3)**: Files API·user_id — 수요 판정 후 별도 RFC.

## 검증

- 각 Phase 늬 카탈로그 변경 후 `dune build @check` 와 모델 카탈로그 파티티
  테스트(masc ci 스탠자)를 통과시킨다.
- P0 실측: deepseek 직접 런타임으로 1회 thinking+tools 턴을 라이브에서
  돌려 (a) 400 없이 회귀 (b) usage 의 cache hit/miss 필드 파싱 (c) 강제
  tool_choice 수용 여부를 확인한다. 결과를 이 RFC 의 Phase 0 항목에
  기록한다.
- 가격·배율은 과금 회계(cost_ledger)의 단가와 대조한다.

## 관계

- 런타임 체인 등록(2026-09-06, runtime.toml lane 3곳 + `[providers.deepseek]`)은
  본 RFC 이전에 적용됐다.
- ollama_cloud deepseek 행의 `reasoning_replay` 선례(`:0731` 행 주석,
  2026-08-24)가 Phase 0 의 참조다.
