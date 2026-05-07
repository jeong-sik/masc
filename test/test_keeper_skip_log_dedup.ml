(* Dedup tests for keeper_skip_log_dedup.  Pure synchronous; no I/O. *)

let test_dedup_blocks_same_within_ttl () =
  let now = 0.0 in
  let ttl = 10.0 in
  Alcotest.(check bool) "first emit" true
    (Masc_mcp.Keeper_skip_log_dedup.should_emit ~keeper_name:"k1"
       ~reasons:["keeper_paused"; "scheduled_autonomous_disabled"]
       ~now ~ttl_sec:ttl);
  Alcotest.(check bool) "same within ttl" false
    (Masc_mcp.Keeper_skip_log_dedup.should_emit ~keeper_name:"k1"
       ~reasons:["keeper_paused"; "scheduled_autonomous_disabled"]
       ~now:(now +. 5.0) ~ttl_sec:ttl);
  Alcotest.(check bool) "ttl boundary" true
    (Masc_mcp.Keeper_skip_log_dedup.should_emit ~keeper_name:"k1"
       ~reasons:["keeper_paused"; "scheduled_autonomous_disabled"]
       ~now:(now +. 10.0) ~ttl_sec:ttl)

let test_dedup_different_reasons_transition () =
  let now = 0.0 in
  let ttl = 10.0 in
  Alcotest.(check bool) "first" true
    (Masc_mcp.Keeper_skip_log_dedup.should_emit ~keeper_name:"k2"
       ~reasons:["keeper_paused"] ~now ~ttl_sec:ttl);
  Alcotest.(check bool) "different reasons" true
    (Masc_mcp.Keeper_skip_log_dedup.should_emit ~keeper_name:"k2"
       ~reasons:["approval_pending"] ~now:(now +. 1.0) ~ttl_sec:ttl)

let test_dedup_sorted_normalises () =
  let now = 0.0 in
  let ttl = 10.0 in
  Alcotest.(check bool) "order a" true
    (Masc_mcp.Keeper_skip_log_dedup.should_emit ~keeper_name:"k3"
       ~reasons:["keeper_paused"; "approval_pending"] ~now ~ttl_sec:ttl);
  Alcotest.(check bool) "order b same set" false
    (Masc_mcp.Keeper_skip_log_dedup.should_emit ~keeper_name:"k3"
       ~reasons:["approval_pending"; "keeper_paused"]
       ~now:(now +. 1.0) ~ttl_sec:ttl)

let test_zero_ttl_always_emits () =
  Alcotest.(check bool) "zero ttl" true
    (Masc_mcp.Keeper_skip_log_dedup.should_emit ~keeper_name:"k4"
       ~reasons:["keeper_paused"] ~now:0.0 ~ttl_sec:0.0)

let () =
  Alcotest.run "keeper_skip_log_dedup" [
    "dedup", [
      Alcotest.test_case "blocks_same_within_ttl" `Quick
        test_dedup_blocks_same_within_ttl;
      Alcotest.test_case "allows_different_reasons" `Quick
        test_dedup_different_reasons_transition;
      Alcotest.test_case "sorted_normalises" `Quick
        test_dedup_sorted_normalises;
      Alcotest.test_case "zero_ttl_always_emits" `Quick
        test_zero_ttl_always_emits;
    ]
  ]
