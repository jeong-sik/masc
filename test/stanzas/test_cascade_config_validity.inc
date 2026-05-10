; Static validity check for the committed cascade seed.
; Feeds every materialized profile's model string list through the OAS parser
; (parse_model_string_exn) so unknown provider names fail at test time
; rather than when a keeper actually tries to resolve the cascade at
; runtime. Path is injected via env var, not hardcoded.
; Also asserts that committed config/cascade.json exactly matches the
; materialized output of config/cascade.toml, keeping TOML as the
; human-authored SSOT.
;
; The test uses parse_model_string_exn and explicitly accepts the
; "provider unavailable" error path, so the file-level (ZAI_API_KEY "")
; default does NOT need to be overridden here — a known provider with
; an unset API key is a soft pass, only unknown providers hard-fail.

(test
 (name test_cascade_config_validity)
 (modules test_cascade_config_validity)
 (deps
  %{workspace_root}/config/cascade.json
  %{workspace_root}/config/cascade.toml)
 (action
  (setenv MASC_CASCADE_JSON_PATH %{workspace_root}/config/cascade.json
   (run %{test})))
 (libraries masc_test_deps))
