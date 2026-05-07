; RFC-0041 PR-A — Endpoint registry drift guards.
; See test/test_endpoint.ml for the structural invariants and the four
; §2.1 wire-level surprises (kimi-api hybrid, ollama ndjson, gemini_cli
; no-per-call-MCP, GLM no-/v1).

(test
 (name test_endpoint)
 (modules test_endpoint)
 (libraries masc_test_deps))
