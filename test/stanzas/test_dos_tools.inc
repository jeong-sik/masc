; DOS lane tools — handler-level tests over the real misc dispatch. The tests
; assemble their own COM program, so CI carries no game image.
(test
 (name test_dos_tools)
 (modules test_dos_tools)
 (libraries
  alcotest yojson unix eio_main fs_compat masc masc.dos_lane masc.board_handlers
  masc.masc_core masc.tool_types masc.masc_tool_dispatch masc.tool_schemas
  masc.masc_types))
