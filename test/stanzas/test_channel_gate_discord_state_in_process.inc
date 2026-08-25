; RFC-0203 Phase 3 — in-process gateway support in
; Channel_gate_discord_state.
;
; The gate reads MASC_BASE_PATH, and test/dune deliberately blanks it so no
; suite binds to a real workspace, so this action names its own.

(test
 (name test_channel_gate_discord_state_in_process)
 (modules test_channel_gate_discord_state_in_process)
 (action
  (setenv MASC_BASE_PATH /tmp/test-channel-gate-discord-in-process
   (setenv MASC_BASE_PATH_INPUT /tmp/test-channel-gate-discord-in-process
    (run %{test}))))
 (libraries masc_test_deps))
