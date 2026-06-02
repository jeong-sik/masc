; Shell IR Adjacent Surfaces Plan P12 — ratchet test that blocks new
; raw Bash.parse_string / Exec_gate.run_argv* call-sites in lib/.

(test
 (name test_shell_parse_site_ratchet)
 (modules test_shell_parse_site_ratchet)
 (libraries masc_test_deps unix str))
