# Account readiness boundary, 2026-09-28

This is a two-request readiness observation, not the Stagehand fixture matrix.
The replacement identity/slot order came from reviewed catalog proposal #39434,
source `f8f04e2d553a5be8c7a1253634b97e97a118d508`.

One direct chat-completion request per slot asked for `OK`, with stream=false,
max_tokens=64 and an explicit 60-second transport observation deadline. The
replacement model retained its declared low reasoning effort. No retries or
synthetic failover were used. Credentials were read from the providers' existing
environment references. No live configuration changed; no raw response or
credential is retained in this evidence.

- `glm-coding.glm-5-3` / API `glm-5.3`: HTTP 429, 1/1. The primary account
  prerequisite remains unmet; no claim is made about the rate limit's cause.
- `ollama_cloud.ollama-cloud-deepseek-v4-1-flash` / API
  `deepseek-v4.1-flash`: HTTP 200, 1/1, nonempty message with finish_reason=stop.
  This establishes acceptance of this small request only. It does not establish
  Extract/Progress/Act correctness, an N/M success rate, or real failover.

The previously committed failed 27-call run is unchanged. A full rerun remains
blocked by primary-account readiness; the successful small fallback request
cannot replace that condition. Exact typed status, elapsed time, request hash,
slot identity and observation timestamp are in `readiness.json`.
