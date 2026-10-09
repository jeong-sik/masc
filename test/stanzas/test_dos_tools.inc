; DOS lane tools — worker handlers and attached Keeper dispatch. The tests
; assemble their own COM program, so CI carries no game image.
(test
 (name test_dos_tools)
 (modules test_dos_tools)
 (libraries masc.embedded_config machine_worker_fixture mcp_protocol masc.dos_tools
  masc.machine_configuration
  alcotest yojson unix digestif eio_main fs_compat masc masc.dos_lane masc.machine_checkpoint
  ocaml-dos.core-identity
  masc.board_handlers
  masc.masc_core masc.tool_types masc.masc_tool_dispatch masc.tool_schemas
  masc.masc_types masc_test_deps))
