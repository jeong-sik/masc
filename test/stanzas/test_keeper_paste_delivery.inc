; Paste delivery to endpoint-owned keeper workspaces: staged spilled-paste
; files are selected out of the bundle, written through the injected or the
; production remote-lane transport, and retained when the write fails
; (failure_keeps_evidence). The stub endpoint pins where the delivery lands.
(test
 (name test_keeper_paste_delivery)
 (modules test_keeper_paste_delivery)
 (libraries astring masc_test_deps masc_tui_paste_spill exec_ssh_protocol eio_main))
