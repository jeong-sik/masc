(test
 (name test_recipient_replay)
 (modules test_recipient_replay)
 (deps ../tools/recipient_replay/main.exe)
 (libraries alcotest masc.board_handlers yojson unix))
