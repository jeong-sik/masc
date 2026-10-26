; Dos_lane autosave guard — a load never moves or replaces an autosave file
; without the caller's consent, and a worker's start resumes the autosave
; without moving either file. Lane level, no tool layer.
(test
 (name test_dos_lane_autosave)
 (modules test_dos_lane_autosave)
 (libraries alcotest unix masc.dos_lane masc.machine_action_feed masc.machine_checkpoint
  masc.machine_configuration))
