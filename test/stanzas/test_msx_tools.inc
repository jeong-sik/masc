; MSX lane tools (RFC-0439 §6.1) — handler-level tests over the real misc
; dispatch, with a ROM-less machine (the bus reads 0xFF) so no game image is
; needed in CI.
(test
 (name test_msx_tools)
 (modules test_msx_tools)
 (libraries
  alcotest yojson fs_compat masc masc.msx_lane
  masc.tool_types masc.masc_tool_dispatch masc.tool_schemas masc.masc_types))
