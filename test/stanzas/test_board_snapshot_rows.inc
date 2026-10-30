; Board posts and comments snapshots re-render only replaced values

(test
 (name test_board_snapshot_rows)
 (modules test_board_snapshot_rows)
 (libraries alcotest masc.board_handlers yojson))
