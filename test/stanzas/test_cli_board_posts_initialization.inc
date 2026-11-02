; Actual Cmdliner routing and real filesystem commands with structured output.
(test
 (name test_cli_board_posts_initialization)
 (modules test_cli_board_posts_initialization)
 (libraries masc_cli_board_posts_initialization masc.board_handlers
  alcotest cmdliner unix yojson))
