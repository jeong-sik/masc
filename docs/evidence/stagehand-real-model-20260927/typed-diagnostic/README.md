# Typed failure diagnosis

Result: 0/27 valid. This remains failed real-model evidence for #38739.

The exact fedd7dba source artifact and actual model regression passed CI before this host measurement. Both host offline controls passed. The isolated 27-call run exited 1 after 13.175 seconds. It uses the same configured primary/fallback slots and recorded Extract/Progress/Act requests as the earlier run; the diagnostic observer preserves the production Model.create execution path.

| Route | Invocations | Typed outcome |
|---|---:|---|
| Primary glm-coding.glm-5-3 | 9 | HTTP 429, rate_limited |
| Fallback ollama_cloud.deepseek-v4-flash | 9 | HTTP 410, invalid_request |
| Injected primary 503 then real fallback | 9 | Visit 1 HTTP 503, then visit 2 HTTP 410 |

Each request kind has 3 attempts per route. The injected-primary route proves the actual candidate walk advances to the real fallback, which refuses all requests. It does not prove successful failover. No response reached schema or semantic validation, so these observations do not establish a model-format defect. HTTP 410 alone does not distinguish model retirement from endpoint/provider policy; that requires authoritative provider evidence.

These facts diagnose this execution only. The earlier c541 run had 3 valid primary Act responses and 24 coarse refusals; its lost detail cannot be reconstructed from this later measurement. Credentials, raw provider responses, private logs and host paths are excluded. No live runtime or browser state was changed.

See results.jsonl for every typed cause/candidate ordinal, execution.json for binary identity/timing, and artifact-manifest.json for file hashes. Build run 36266258730; actual fixture test run 36266256510.
