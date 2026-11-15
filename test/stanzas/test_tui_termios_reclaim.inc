; #49845: the keys raw mode takes back from the tty, read on a real pty by
; python3 (the precedent is test_start_masc_script). unix runs that fixture.
(test
 (name test_tui_termios_reclaim)
 (modules test_tui_termios_reclaim)
 (libraries alcotest masc_tui_termios unix))
