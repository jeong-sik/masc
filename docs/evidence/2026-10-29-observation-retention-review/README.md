# 관측 유실 클래스 — 외부 리뷰 원문 (2026-10-28~29)

RFC-0477의 근거 원문. 동일 브리핑(`brief.md`)을 5회 독립 실행해 모은 답변이다.
원문 그대로 보존하며, 출력 노이즈(실행 헤더·token 집계)도 남긴다.

| 파일 | 실행 경로 | 실제 모델 |
|---|---|---|
| brief.md | — | 질문 원문. 최초 판정(단일 ⊇ 불변식 + round-trip 의무) 포함 |
| review-1-codex-gpt.md | codex-cli 0.165.0 | GPT 계열 Codex. 저장소 파일 직독(131k tokens) |
| review-2-claude-slot-glm-routed.md | `claude -p --model opus` | 세션 환경 상속으로 GLM 라우팅. 헤더의 `unrecognized_model: glm-5.3[1m]` 경로 근거 |
| review-3-claude-slot-glm-routed.md | `claude -p --model fable` | 위와 같음. 두 실행은 사실상 같은 기저 모델 |
| review-4-anthropic-opus.md | env 정리 후 `claude -p --model opus` | Anthropic Opus. 헤더 경고 없음 |
| review-5-anthropic-fable.md | env 정리 후 `claude -p --model fable` | Anthropic Fable. #46595·#46589·#46599 인용은 gh PR 확인으로 검증(2026-10-29, 전부 OPEN) |

집계: 5건 전원이 최초 판정의 ⊇ 불변식을 기각. RFC-0477 §7에 기각 사유 요약,
본 디렉터리에 원문.
