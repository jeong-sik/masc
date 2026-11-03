(test
 (name test_pending_confirm_expiry)
 (modules test_pending_confirm_expiry)
 (libraries alcotest eio eio_main unix masc masc.operator masc.masc_types masc.masc_core
  masc.fs_compat masc.wall_deadline masc_server masc_test_deps masc_workspace))
