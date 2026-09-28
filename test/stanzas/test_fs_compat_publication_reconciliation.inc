(test
 (name test_fs_compat_publication_reconciliation)
 (modules test_fs_compat_publication_reconciliation)
 (libraries
  alcotest
  fs_compat
  fs_compat_test_support
  fs_compat_internal
  eio
  eio_main
  eio.unix
  unix
  uuidm
  yojson
  digestif))
