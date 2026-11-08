; The gate of a multi-account request (Auth_gate.decide) on real files in a
; temporary directory: each row sends one request to one kind of route and
; reads who it acts as, or why it is refused. No network.

(test
 (name test_auth_gate)
 (modules test_auth_gate)
 (libraries masc_test_deps))
