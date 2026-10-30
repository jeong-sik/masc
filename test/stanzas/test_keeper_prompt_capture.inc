; The extra system context a turn assembled, captured as text. Round-trip and
; boundary cases: an unknown block id must reject rather than decode short.

(test
 (name test_keeper_prompt_capture)
 (modules test_keeper_prompt_capture)
 (libraries alcotest astring masc masc_test_deps masc_types str unix))
