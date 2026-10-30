; Dos_lane program images — the check that keeps the core's loader exceptions
; from reaching a caller, run beside the real loader.
(test
 (name test_dos_lane_image)
 (modules test_dos_lane_image)
 (libraries alcotest unix masc.dos_lane masc.machine_configuration ocaml-dos.dosmachine))
