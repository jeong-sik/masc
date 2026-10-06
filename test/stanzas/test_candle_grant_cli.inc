(rule
 (alias runtest-test_candle_grant_cli)
 (deps test_candle_grant_cli.py ../bin/masc_candle_grant.exe)
 (action (run python3 %{dep:test_candle_grant_cli.py} %{dep:../bin/masc_candle_grant.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_candle_grant_cli)))
