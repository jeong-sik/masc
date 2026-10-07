; Machine_action_feed — the spectator feed's push/cap/JSON logic, no machine lane.
(test
 (name test_machine_action_feed)
 (modules test_machine_action_feed)
 (libraries alcotest yojson masc.machine_action_feed))
