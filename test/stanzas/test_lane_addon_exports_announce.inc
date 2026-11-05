(test
 (name test_lane_addon_exports_announce)
 (modules test_lane_addon_exports_announce)
 (libraries alcotest eio eio_main unix masc masc.masc_types masc.masc_core
  masc.fs_compat masc_server masc_test_deps masc_workspace yojson))
