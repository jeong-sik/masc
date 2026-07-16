; Regression guard: Discord gateway TLS config is cached process-wide
; (trust store loaded once, not per reconnect).
(test
 (name test_discord_tls_config_cache)
 (modules test_discord_tls_config_cache)
 (libraries alcotest masc.gate))
