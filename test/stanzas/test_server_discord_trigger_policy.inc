; F941 — server trigger-policy parser delegates to the single strict
; grammar. Links masc_test_deps for masc.server (Server_discord_*).
(test
 (name test_server_discord_trigger_policy)
 (modules test_server_discord_trigger_policy)
 (libraries alcotest masc_test_deps))
