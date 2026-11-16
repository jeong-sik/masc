; RFC a-fiber-that-suspends-while-holding-an-os-mutex-fails-at-unlock §6.1: a
; section whose Eio fiber switches while it holds an Os_mutex fails when it
; ends. The cases call Eio_posix.run, the backend masc pins (D6). Case 9 runs
; this executable again as a child that hangs.
(test
 (name test_os_mutex)
 (modules test_os_mutex)
 (libraries
  alcotest
  masc.agent_core.os_mutex
  masc.agent_core.strings
  masc.fs_compat
  masc.masc_core
  eio
  eio.unix
  eio_posix
  unix))
