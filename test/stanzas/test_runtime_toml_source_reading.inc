; Runtime_toml keeps the reading of the source text it parsed last, for the
; same text under the same home.

(test
 (name test_runtime_toml_source_reading)
 (modules test_runtime_toml_source_reading)
 (libraries alcotest masc.runtime unix))
