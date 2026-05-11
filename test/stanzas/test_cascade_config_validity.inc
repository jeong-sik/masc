; Static validity check for the cascade catalog, driven from cascade.toml.
; Feeds every materialized profile's model string list through the OAS parser
; (parse_model_string_exn) so unknown provider names fail at test time
; rather than when a keeper actually tries to resolve the cascade at
; runtime. Path to the TOML source is injected via env var, not hardcoded.
;
; RFC-0058 §9 Phase 9.1: cascade.json is no longer committed. The test
; renders cascade.toml in-memory via
; Cascade_toml_materializer.render_toml_to_json_string so the suite has no
; on-disk JSON dependency, and asserts the JSON file stays untracked.
;
; The test uses parse_model_string_exn and explicitly accepts the
; "provider unavailable" error path, so the file-level (ZAI_API_KEY "")
; default does NOT need to be overridden here — a known provider with
; an unset API key is a soft pass, only unknown providers hard-fail.

(test
 (name test_cascade_config_validity)
 (modules test_cascade_config_validity)
 (deps %{workspace_root}/config/cascade.toml)
 (action
  (setenv MASC_CASCADE_TOML_PATH %{workspace_root}/config/cascade.toml
   (run %{test})))
 (libraries masc_test_deps))
