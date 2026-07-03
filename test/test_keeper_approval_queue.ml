(** Tests for the typed pending_phase HITL state machine (RFC-0304).

    Proves:
    1. Fresh pending approvals start in [Awaiting_operator].
    2. The phase is included in pending-entry JSON/SSE payloads.
    3. Critical approvals transition to [Escalated] when the escalation timer
       fires, and the updated phase is reflected in-memory and in JSON. *)

module AQ = Masc.Keeper_approval_queue

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_approval_queue_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec rm_rf path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  try rm_rf dir with
  | _ -> ()
;;

let rec yield_until ?(attempts = 50) predicate =
  if predicate () || attempts <= 0
  then ()
  else (
    Eio.Fiber.yield ();
    yield_until ~attempts:(attempts - 1) predicate)
;;

let pending_id_for_keeper ~keeper_name =
  match AQ.list_pending_json () with
  | `List entries ->
    List.find_map
      (function
        | `Assoc kvs ->
          (match List.assoc_opt "keeper_name" kvs, List.assoc_opt "id" kvs with
           | Some (`String name), Some (`String id) when String.equal name keeper_name ->
             Some id
           | _ -> None)
        | _ -> None)
      entries
  | _ -> None
;;

let phase_in_json json =
  let open Yojson.Safe.Util in
  json |> member "phase" |> to_string
;;

let test_fresh_critical_entry_phase_is_awaiting_operator () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let keeper_name = "fresh-critical-phase-test" in
       let result = ref None in
       Eio.Fiber.fork ~sw (fun () ->
         let decision =
           AQ.submit_and_await
             ~keeper_name
             ~tool_name:"keeper_continue_after_reconcile"
             ~input:(`Assoc [ ("kind", `String "critical_gate") ])
             ~risk_level:AQ.Critical
             ~base_path
             ()
         in
         result := Some decision);
       yield_until (fun () -> Option.is_some (pending_id_for_keeper ~keeper_name));
       let id =
         match pending_id_for_keeper ~keeper_name with
         | Some id -> id
         | None -> Alcotest.fail "Critical approval was not queued"
       in
       let entry =
         match AQ.For_testing.get_pending_entry ~id with
         | Some entry -> entry
         | None -> Alcotest.fail "in-memory entry not found"
       in
       Alcotest.(check bool)
         "fresh Critical entry is Awaiting_operator in-memory"
         true
         (entry.phase = AQ.Awaiting_operator);
       let detail =
         match AQ.get_pending_json ~id with
         | Some json -> json
         | None -> Alcotest.fail "pending detail JSON not found"
       in
       Alcotest.(check string)
         "fresh Critical entry is awaiting_operator in JSON"
         "awaiting_operator"
         (phase_in_json detail);
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err ->
          Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
       yield_until (fun () -> Option.is_some !result);
       match !result with
       | Some Agent_sdk.Hooks.Approve -> ()
       | Some decision ->
         Alcotest.fail
           ("expected Approve, got " ^ AQ.approval_decision_to_string decision)
       | None -> Alcotest.fail "Critical approval did not resume after resolve")
;;

let test_critical_entry_phase_becomes_escalated_after_timer () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let base_path = temp_dir () in
  AQ.For_testing.reset_audit_store ();
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_audit_store ();
      cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let keeper_name = "critical-escalated-phase-test" in
       let result = ref None in
       Eio.Fiber.fork ~sw (fun () ->
         let decision =
           AQ.submit_and_await
             ~keeper_name
             ~tool_name:"keeper_continue_after_partial_commit"
             ~input:(`Assoc [ ("kind", `String "critical_gate") ])
             ~risk_level:AQ.Critical
             ~base_path
             ~clock
             ~critical_escalation_after_s:0.01
             ()
         in
         result := Some decision);
       yield_until (fun () -> Option.is_some (pending_id_for_keeper ~keeper_name));
       let id =
         match pending_id_for_keeper ~keeper_name with
         | Some id -> id
         | None -> Alcotest.fail "Critical approval was not queued"
       in
       Eio.Time.sleep clock 0.03;
       yield_until (fun () ->
         match AQ.For_testing.get_pending_entry ~id with
         | Some entry -> entry.phase = AQ.Escalated
         | None -> false);
       let entry =
         match AQ.For_testing.get_pending_entry ~id with
         | Some entry -> entry
         | None -> Alcotest.fail "in-memory entry missing after escalation"
       in
       Alcotest.(check bool)
         "Critical entry is Escalated in-memory after timer"
         true
         (entry.phase = AQ.Escalated);
       let detail =
         match AQ.get_pending_json ~id with
         | Some json -> json
         | None -> Alcotest.fail "pending detail JSON missing after escalation"
       in
       Alcotest.(check string)
         "Critical entry is escalated in JSON after timer"
         "escalated"
         (phase_in_json detail);
       Alcotest.(check bool)
         "Critical escalation does not auto-resolve"
         true
         (Option.is_none !result);
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err ->
          Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
       yield_until (fun () -> Option.is_some !result);
       match !result with
       | Some Agent_sdk.Hooks.Approve -> ()
       | Some decision ->
         Alcotest.fail
           ("expected Approve, got " ^ AQ.approval_decision_to_string decision)
       | None -> Alcotest.fail "Critical approval did not resume after escalation")
;;

let test_pending_phase_conversions () =
  Alcotest.(check string)
    "Awaiting_operator string"
    "awaiting_operator"
    (AQ.pending_phase_to_string AQ.Awaiting_operator);
  Alcotest.(check string)
    "Escalated string"
    "escalated"
    (AQ.pending_phase_to_string AQ.Escalated);
  Alcotest.(check bool)
    "parse awaiting_operator"
    true
    (match AQ.pending_phase_of_string "awaiting_operator" with
     | Some AQ.Awaiting_operator -> true
     | _ -> false);
  Alcotest.(check bool)
    "parse escalated"
    true
    (match AQ.pending_phase_of_string "escalated" with
     | Some AQ.Escalated -> true
     | _ -> false);
  Alcotest.(check bool)
    "unknown phase returns None"
    true
    (Option.is_none (AQ.pending_phase_of_string "unknown"))
;;

let () =
  Alcotest.run
    "Keeper_approval_queue"
    [ ( "phase"
      , [ Alcotest.test_case
            "fresh Critical entry starts in Awaiting_operator"
            `Quick
            test_fresh_critical_entry_phase_is_awaiting_operator
        ; Alcotest.test_case
            "Critical entry becomes Escalated after escalation timer"
            `Quick
            test_critical_entry_phase_becomes_escalated_after_timer
        ] )
    ; ( "conversions"
      , [ Alcotest.test_case
            "pending_phase string conversions round-trip"
            `Quick
            test_pending_phase_conversions
        ] )
    ]
;;
