; Lane_activity — the spectator feed's push/cap/JSON logic, no machine lane.
(test
 (name test_lane_activity)
 (modules test_lane_activity)
 (libraries alcotest yojson masc.lane_activity))
