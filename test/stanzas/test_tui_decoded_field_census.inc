; #38446: the census of TUI record fields a decoder fills and nothing reads,
; over lib/tui_decode.ml and the bin/ decoders, checked on small trees.
(rule
 (alias runtest-test_tui_decoded_field_census)
 (deps
  test_tui_decoded_field_census.py
  ../scripts/tui-decoded-field-census.py)
 (action
  (run python3 %{dep:test_tui_decoded_field_census.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_decoded_field_census)))
