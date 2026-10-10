; MSX worker handler tests with a ROM-less machine.
(test
 (name test_msx_tools)
 (modules test_msx_tools)
 ; lane 28 reads the pin script and the lock file from the source root.
 (deps ../scripts/opam-pin-external-deps.sh ../masc.opam.locked)
 (libraries masc.embedded_config masc.msx_tools
  masc.machine_configuration
  alcotest yojson unix eio_main fs_compat ocaml-msx.msx masc masc.msx_lane masc.board_handlers
  masc.tool_types masc.masc_tool_dispatch masc.tool_schemas masc.masc_types
  masc.keeper_metrics masc.agent_core digestif))
