(rule
 (alias runtest-test_tui_candle_currency_pty)
 (deps test_tui_candle_currency_pty.py
  tui_keyboard_harness.py ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_candle_currency_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_candle_currency_pty)))
