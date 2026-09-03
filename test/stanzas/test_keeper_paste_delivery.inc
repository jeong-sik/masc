; Paste delivery to endpoint-owned keeper workspaces: staged [pasted-*.txt]
; files are selected out of the bundle, written through the injected
; transport, and retained when the write fails (failure_keeps_evidence).
(test
 (name test_keeper_paste_delivery)
 (modules test_keeper_paste_delivery)
 (libraries masc_test_deps))
