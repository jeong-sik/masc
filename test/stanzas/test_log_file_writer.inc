(test
 (name test_log_file_writer)
 (modules test_log_file_writer)
 (libraries
  masc.masc_log
  alcotest
  eio
  eio_main
  unix
  threads.posix
  yojson))
