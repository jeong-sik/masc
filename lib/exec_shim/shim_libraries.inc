; The shim's libraries, read by two builds: lib/exec_shim/dune includes this
; file, and scripts/build-shim-static.sh copies it into its scratch project
; and includes it there. One declaration, so a library or stub added here
; reaches both builds; a hand-kept copy in the script once left out
; shim_fdpass and the static build stopped linking.

; A leaf library rather than a module of exec_shim: the shim library's own
; module carries the library's name, so nothing outside it can reach a
; sibling module, and this one has a test. The C stub lives with the module
; that declares its external.
(library
 (name shim_clock)
 (wrapped false)
 (modules shim_clock)
 (foreign_stubs
  (language c)
  (names monotonic_stub)))

; task-1568 phase 2.  A leaf library for the same reason shim_clock is one:
; the stub's external is declared by this module, and a test links it
; directly without pulling in the whole shim.
(library
 (name shim_fdpass)
 (wrapped false)
 (modules shim_fdpass)
 (libraries unix)
 (foreign_stubs
  (language c)
  (names fdpass_stub)))

(library
 (name exec_shim)
 (modules exec_shim shim_build_id)
 (libraries exec_ssh_protocol shim_clock shim_fdpass unix)
 (foreign_stubs
  (language c)
  (names prctl_stub observe_stub)))
