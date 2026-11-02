; The actual configured lease adapter, including aliases and this-process owners.
(test
 (name test_board_posts_initialization_offline)
 (modules test_board_posts_initialization_offline)
 (libraries masc_test_deps masc masc.server masc.host_config masc.board_handlers fs_compat alcotest unix yojson
  eio eio_main))
