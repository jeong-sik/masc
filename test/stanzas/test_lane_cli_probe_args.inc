; Pins what masc-lane-cli-probe accepts and rejects: every rejection is an
; Error the executable turns into usage plus exit 2, and --trials must be a
; positive integer.

(test
 (name test_lane_cli_probe_args)
 (modules test_lane_cli_probe_args)
 (libraries alcotest masc_lane_cli_probe_args))
