; Not a test: prints how long a schedule ledger mutation and the read after it
; take for a ledger of a given size. Run by hand from _build/default/test.

(executable
 (name bench_schedule_ledger_write_read)
 (modules bench_schedule_ledger_write_read)
 (libraries
  eio
  eio_main
  fs_compat
  masc_core
  masc_test_deps
  masc_workspace
  masc_schedule
  unix
  yojson))
