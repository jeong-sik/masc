; Static validity check for the committed config/cascade.json.
; Feeds every profile's model string list through the OAS parser
; (parse_model_string_exn) so unknown provider names fail at test time
; rather than when a keeper actually tries to resolve the cascade at
; runtime. Path is injected via env var, not hardcoded.
;
; The test uses parse_model_string_exn and explicitly accepts the
; "provider unavailable" error path, so the file-level (ZAI_API_KEY "")
; default does NOT need to be overridden here — a known provider with
; an unset API key is a soft pass, only unknown providers hard-fail.

(test
 (name test_cascade_config_validity)
 (modules test_cascade_config_validity)
 (deps %{workspace_root}/config/cascade.json)
 (action
  (setenv MASC_CASCADE_JSON_PATH %{workspace_root}/config/cascade.json
   (run %{test})))
 (libraries masc_test_deps))
