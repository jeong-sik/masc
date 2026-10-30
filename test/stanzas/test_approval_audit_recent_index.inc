; Keeper_approval.Audit.read_recent — the incremental index answers as the backward scan

(test
 (name test_approval_audit_recent_index)
 (modules test_approval_audit_recent_index)
 (libraries alcotest eio eio_main masc.masc_core masc.keeper_approval masc.dated_jsonl unix yojson))
