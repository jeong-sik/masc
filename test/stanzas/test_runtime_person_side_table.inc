; Person runtime side-table lookup, dir preparation, candidate_backpressure
; preservation across reload, no default-route fallback, and RFC 6.5 usage
; isolation in multi-account mode.
; Lists libraries without masc_test_deps because masc_test_deps auto-publishes
; single-user access at startup.

(test
 (name test_runtime_person_side_table)
 (modules test_runtime_person_side_table)
 (libraries
  alcotest
  eio
  eio.unix
  eio_main
  masc
  masc.agent_core.llm_provider
  masc.auth
  masc.fs_compat
  masc.masc_core
  masc.runtime
  unix
  yojson))
