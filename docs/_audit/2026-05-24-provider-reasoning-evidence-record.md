# Provider reasoning-control evidence record - 2026-05-24

Scope: #1706 first implementation slice. This records the provider-facing
wire-format facts used to set OAS `thinking_control_format` values and GLM
coding credential separation.

## OpenAI

- Evidence: OpenAI Chat Completions documents `reasoning_effort` as the request
  parameter for reasoning models, with currently documented values including
  `none`, `minimal`, `low`, `medium`, `high`, and `xhigh`.
- Source: https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
- Timestamp: 2026-05-24 KST
- Confidence: High
- Delta: OAS maps OpenAI-style reasoning records to `Reasoning_effort`.

## Z.AI

- Evidence: Z.AI documents the general API endpoint
  `https://api.z.ai/api/paas/v4` and a distinct GLM Coding Plan endpoint
  `https://api.z.ai/api/coding/paas/v4`.
- Source: https://docs.z.ai/api-reference/introduction
- Timestamp: 2026-05-24 KST
- Confidence: High
- Delta: OAS keeps general GLM on `ZAI_API_KEY` and defaults the coding lane to
  `ZAI_CODING_API_KEY`.

## Kimi / Moonshot

- Evidence: Kimi K2.5 request-body differences document a top-level `thinking`
  object. Thinking can be disabled with `{"type": "disabled"}`, and thinking
  output is surfaced as `reasoning_content`.
- Source: https://platform.kimi.ai/docs/guide/kimi-k2-5-quickstart
- Timestamp: 2026-05-24 KST
- Confidence: High
- Delta: OAS maps Kimi K2.5-style reasoning control to `Thinking_object_only`
  rather than mixing it with `reasoning_effort`.

## DashScope

- Evidence: DashScope OpenAI-compatible deep-thinking examples show top-level
  `enable_thinking` and `thinking_budget` fields and stream
  `reasoning_content`.
- Source: https://help.aliyun.com/zh/model-studio/deep-thinking
- Timestamp: 2026-05-24 KST
- Confidence: High
- Delta: OAS maps DashScope reasoning control to `Enable_thinking`.
