; Actual noncreating observations and offline publication receipts.
(test
 (name test_board_posts_initialization)
 (modules test_board_posts_initialization)
 (libraries masc masc.board_handlers masc.agent_core.digest fs_compat alcotest
  unix yojson eio eio.unix eio_main))
