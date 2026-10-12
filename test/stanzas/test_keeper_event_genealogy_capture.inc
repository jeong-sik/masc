; Research capture, run on request:
;   dune exec --root . test/test_keeper_event_genealogy_capture.exe -- -v
; It builds each experimental request by replacing two declared prompt spans
; verbatim, so it pins prompt wording. The regression suite does not run it
; (docs/constitution.xml execution_protocol: no wording or snapshot checks
; without a functional failure).
(executable
 (name test_keeper_event_genealogy_capture)
 (modules test_keeper_event_genealogy_capture)
 (libraries masc_test_deps exact_output_fixture masc masc.runtime masc.masc_eio_context agent_core eio_main))
