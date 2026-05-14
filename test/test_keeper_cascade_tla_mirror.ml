(* Tests for KeeperCascadeRouting TLA+ spec mirror. *)

let test_provider_outcome_ppx_tla () =
  let open Masc_mcp.Cascade_fsm in
  Alcotest.(check (list string))
    "all_symbols provider_outcome"
    ["call_ok"; "call_err"; "accept_rejected"; "slot_full"]
    all_symbols;
  Alcotest.(check string) "Slot_full symbol" "slot_full"
    (to_tla_symbol Slot_full);
  Alcotest.(check bool) "Call_ok is not terminal (no @tla.terminal)" false
    (is_terminal (Call_ok (Obj.magic ())));
  Alcotest.(check bool) "Slot_full is not terminal (no @tla.terminal)" false
    (is_terminal Slot_full)
;;

let test_decide_call_ok () =
  let d =
    Masc_mcp.Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last:false
      (Call_ok (Obj.magic ()))
  in
  match d with
  | Masc_mcp.Cascade_fsm.Accept _ -> ()
  | _ -> Alcotest.fail "Call_ok must map to Accept"
;;

let test_decide_slot_full () =
  let d =
    Masc_mcp.Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last:false
      Slot_full
  in
  match d with
  | Masc_mcp.Cascade_fsm.Try_next _ -> ()
  | _ -> Alcotest.fail "Slot_full must map to Try_next"
;;

let test_decide_accept_rejected () =
  let dummy = Obj.magic () in
  let d1 =
    Masc_mcp.Cascade_fsm.decide ~accept_on_exhaustion:true ~is_last:true
      (Accept_rejected { response = dummy; reason = "t" })
  in
  (match d1 with
  | Masc_mcp.Cascade_fsm.Accept_on_exhaustion _ -> ()
  | _ -> Alcotest.fail "expected Accept_on_exhaustion");
  let d2 =
    Masc_mcp.Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last:true
      (Accept_rejected { response = dummy; reason = "t" })
  in
  (match d2 with
  | Masc_mcp.Cascade_fsm.Exhausted _ -> ()
  | _ -> Alcotest.fail "expected Exhausted");
  let d3 =
    Masc_mcp.Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last:false
      (Accept_rejected { response = dummy; reason = "t" })
  in
  match d3 with
  | Masc_mcp.Cascade_fsm.Try_next _ -> ()
  | _ -> Alcotest.fail "expected Try_next"
;;

let test_decide_call_err () =
  let err429 =
    Llm_provider.Http_client.HttpError { code = 429; body = "" }
  in
  let d1 =
    Masc_mcp.Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last:false
      (Call_err err429)
  in
  (match d1 with
  | Masc_mcp.Cascade_fsm.Try_next _ -> ()
  | _ -> Alcotest.fail "429 -> Try_next");
  let err400 =
    Llm_provider.Http_client.HttpError { code = 400; body = "" }
  in
  let d2 =
    Masc_mcp.Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last:false
      (Call_err err400)
  in
  match d2 with
  | Masc_mcp.Cascade_fsm.Exhausted _ -> ()
  | _ -> Alcotest.fail "400 -> Exhausted"
;;

let test_should_cascade () =
  Alcotest.(check bool) "429 cascadeable" true
    (Masc_mcp.Cascade_health_filter.should_cascade_to_next
       (Llm_provider.Http_client.HttpError { code = 429; body = "" }));
  Alcotest.(check bool) "400 non-cascadeable" false
    (Masc_mcp.Cascade_health_filter.should_cascade_to_next
       (Llm_provider.Http_client.HttpError { code = 400; body = "" }));
  Alcotest.(check bool) "AcceptRejected non-cascadeable" false
    (Masc_mcp.Cascade_health_filter.should_cascade_to_next
       (Llm_provider.Http_client.AcceptRejected { reason = "t" }))
;;

let () =
  Alcotest.run "KeeperCascadeRouting"
    [ ( "ppx_tla"
      , [ Alcotest.test_case "provider_outcome" `Quick test_provider_outcome_ppx_tla
        ] )
    ; ( "decide"
      , [ Alcotest.test_case "Call_ok" `Quick test_decide_call_ok
        ; Alcotest.test_case "Slot_full" `Quick test_decide_slot_full
        ; Alcotest.test_case "Accept_rejected" `Quick test_decide_accept_rejected
        ; Alcotest.test_case "Call_err" `Quick test_decide_call_err
        ] )
    ; ( "health_filter"
      , [ Alcotest.test_case "should_cascade" `Quick test_should_cascade ] )
    ]
;;
