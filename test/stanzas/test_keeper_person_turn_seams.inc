; RFC N1-S2 A2-2 seams: source.v3 round-trip, batch non-coalescing, exhaustive
; channel routing, PAT admit vs per-attempt recheck, and account call-slot
; ordering / Eio cancellation propagation.
; Lists libraries without masc_test_deps because masc_test_deps auto-publishes
; single-user access at startup.

(test
 (name test_keeper_person_turn_seams)
 (modules test_keeper_person_turn_seams)
 (libraries
  alcotest
  eio
  eio.unix
  eio_main
  masc
  masc.agent_core
  masc.agent_core.llm_provider
  masc.auth
  masc.fs_compat
  masc.keeper_chat_operations
  masc.keeper_registry
  masc.keeper_runtime
  masc.masc_core
  masc.masc_eio_context
  masc.masc_tool_blob_store
  masc.masc_types
  masc.runtime
  sqlite3
  unix
  yojson))
