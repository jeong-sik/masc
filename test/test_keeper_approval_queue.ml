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
         match AQ.get_pending_entry ~id with
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

(* Blocking approvals resume through their live resolver. Non-blocking
   approvals have no suspended fiber, so resolving them must fire the wake hook
   that enqueues a [Hitl_resolved] stimulus. Without that wake the keeper only
   resumes on an unrelated stimulus / no-progress recovery / the 30-minute
   janitor (the reported "HITL 됐는데 핑을 못 받음"). *)
let test_resolve_with_live_resolver_does_not_fire_keeper_wake_hook () =
  Eio_main.run
  @@ fun _env ->
  let base_path = temp_dir () in
  let woke = ref None in
  AQ.set_approval_resolution_wake_hook (fun ~base_path:_ ~keeper_name ~approval_id ~decision ->
    woke := Some (keeper_name, approval_id, decision));
  Fun.protect
    ~finally:(fun () ->
      (* Reset to the default no-op so the recording closure does not leak into
         later tests that share this module-level hook. *)
      AQ.set_approval_resolution_wake_hook
        (fun ~base_path:_ ~keeper_name:_ ~approval_id:_ ~decision:_ -> ());
      cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run
       @@ fun sw ->
       let keeper_name = "resolve-wake-test" in
       let result = ref None in
       Eio.Fiber.fork ~sw (fun () ->
         let decision =
           AQ.submit_and_await
             ~keeper_name
             ~tool_name:"keeper_continue_after_reconcile"
             ~input:(`Assoc [ "kind", `String "critical_gate" ])
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
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err ->
          Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
       (match !woke with
        | Some _ -> Alcotest.fail "live resolver must resume directly without wake hook"
        | None -> ());
       yield_until (fun () -> Option.is_some !result))
;;

let test_submit_pending_resolve_fires_keeper_wake_hook () =
  Eio_main.run
  @@ fun _env ->
  let base_path = temp_dir () in
  let woke = ref None in
  AQ.set_approval_resolution_wake_hook (fun ~base_path:_ ~keeper_name ~approval_id ~decision ->
    woke := Some (keeper_name, approval_id, decision));
  Fun.protect
    ~finally:(fun () ->
      AQ.set_approval_resolution_wake_hook
        (fun ~base_path:_ ~keeper_name:_ ~approval_id:_ ~decision:_ -> ());
      cleanup_dir base_path)
    (fun () ->
       let keeper_name = "pending-resolve-wake-test" in
       let callback_decision = ref None in
       let id =
         AQ.submit_pending
           ~keeper_name
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "critical_gate" ])
           ~risk_level:AQ.Critical
           ~base_path
           ~on_resolution:(fun decision -> callback_decision := Some decision)
           ()
       in
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err ->
          Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
       Alcotest.(check bool)
         "on_resolution callback ran"
         true
         (Option.is_some !callback_decision);
       (match !woke with
        | Some (kn, aid, decision) ->
          Alcotest.(check string) "wake targets the waiting keeper" keeper_name kn;
          Alcotest.(check string) "wake carries the resolved approval id" id aid;
          Alcotest.(check bool)
            "wake carries the typed decision label"
            true
            (decision = Keeper_event_queue.Hitl_approved)
        | None -> Alcotest.fail "non-blocking resolve did not fire the keeper wake hook"))
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
         match AQ.get_pending_entry ~id with
         | Some entry -> entry.phase = AQ.Escalated
         | None -> false);
       let entry =
         match AQ.get_pending_entry ~id with
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

(* Regression: the HITL context summary must survive every JSON emission path,
   including the [include_input:true] dashboard paths. A previous
   [if include_input then ... else [] @ summary] precedence trap parsed the
   trailing summary fields into the [else] branch, so [include_input:true]
   ([list_pending_dashboard_json], [pending_entry_detail_json],
   [broadcast_pending]) silently dropped the operator-facing summary the HITL
   worker had computed. *)
let sample_summary : AQ.hitl_context_summary =
  { summary_version = 1
  ; generated_at = 1_700_000_000.0
  ; model_run_id = "test-model-run"
  ; context_summary = "HITL-SUMMARY-MARKER"
  ; key_questions = [ "is this action reversible?" ]
  ; suggested_options =
      [ { AQ.label = "approve once"
        ; rationale = "blast radius is bounded to the sandbox"
        ; estimated_risk_delta = Some AQ.Low
        }
      ]
  ; risk_rationale = Some "irreversible write outside sandbox"
  ; uncertainty = 0.25
  }
;;

let entry_json_for_keeper ~keeper_name = function
  | `List entries ->
    List.find_opt
      (function
        | `Assoc kvs ->
          (match List.assoc_opt "keeper_name" kvs with
           | Some (`String name) -> String.equal name keeper_name
           | _ -> false)
        | _ -> false)
      entries
  | _ -> None
;;

let context_summary_text_opt json =
  let open Yojson.Safe.Util in
  match json |> member "context_summary" with
  | `Null -> None
  | summary_obj ->
    (match summary_obj |> member "context_summary" with
     | `String s -> Some s
     | _ -> None)
;;

let summary_status_status json =
  let open Yojson.Safe.Util in
  match json |> member "summary_status" with
  | `Null -> None
  | `Assoc _ as obj -> obj |> member "status" |> to_string_option
  | `String s -> Some s
  | _ -> None
;;

let test_summary_survives_include_input_paths () =
  Eio_main.run
  @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run
       @@ fun sw ->
       let keeper_name = "summary-json-emission-test" in
       let result = ref None in
       Eio.Fiber.fork ~sw (fun () ->
         let decision =
           AQ.submit_and_await
             ~keeper_name
             ~tool_name:"keeper_continue_after_reconcile"
             ~input:(`Assoc [ "kind", `String "critical_gate" ])
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
       (* Attach a known summary, then read synchronously (no [yield]) so the
          async summary worker cannot overwrite the entry between write and
          read under Eio's cooperative scheduler. *)
       AQ.update_pending_entry ~id (fun e ->
         { e with
           context_summary = Some sample_summary
         ; summary_status = AQ.Summary_available sample_summary
         });
       let dashboard_entry =
         match
           entry_json_for_keeper ~keeper_name (AQ.list_pending_dashboard_json ())
         with
         | Some json -> json
         | None -> Alcotest.fail "entry missing from list_pending_dashboard_json"
       in
       let detail_entry =
         match AQ.get_pending_json ~id with
         | Some json -> json
         | None -> Alcotest.fail "pending detail JSON not found"
       in
       let list_entry =
         match entry_json_for_keeper ~keeper_name (AQ.list_pending_json ()) with
         | Some json -> json
         | None -> Alcotest.fail "entry missing from list_pending_json"
       in
       let expected = Some "HITL-SUMMARY-MARKER" in
       Alcotest.(check (option string))
         "dashboard list (include_input:true) carries context_summary"
         expected
         (context_summary_text_opt dashboard_entry);
       Alcotest.(check (option string))
         "detail view (include_input:true) carries context_summary"
         expected
         (context_summary_text_opt detail_entry);
       Alcotest.(check (option string))
         "plain list (include_input:false) carries context_summary"
         expected
         (context_summary_text_opt list_entry);
       Alcotest.(check (option string))
         "dashboard list exposes summary_status=available"
         (Some "available")
         (summary_status_status dashboard_entry);
       Alcotest.(check (option string))
         "detail view exposes summary_status=available"
         (Some "available")
         (summary_status_status detail_entry);
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
       | Error err ->
          Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
       yield_until (fun () -> Option.is_some !result))
;;

let test_summary_worker_missing_root_switch_is_explicit_failure () =
  Eio_main.run
  @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run
       @@ fun turn_sw ->
       let keeper_name = "summary-root-switch-missing-test" in
       let id =
         Eio_context.with_turn_switch turn_sw (fun () ->
           AQ.submit_pending
             ~keeper_name
             ~tool_name:"keeper_continue_after_reconcile"
             ~input:(`Assoc [ "kind", `String "medium_gate" ])
             ~risk_level:AQ.Medium
             ~base_path
             ~on_resolution:(fun _decision -> ())
             ())
       in
       let entry =
         match AQ.get_pending_entry ~id with
         | Some entry -> entry
         | None -> Alcotest.fail "pending entry missing"
       in
       (match entry.summary_status with
        | AQ.Summary_failed { reason; retryable } ->
          Alcotest.(check string)
            "missing root switch is explicit"
            "HITL summary: server root switch unavailable"
            reason;
          Alcotest.(check bool) "not retryable without a root switch" false retryable
        | other ->
          Alcotest.failf
            "expected Summary_failed, got %s"
            (Yojson.Safe.to_string (AQ.summary_status_to_yojson other)));
       match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
       | Ok () -> ()
       | Error err ->
         Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err))
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
    ; ( "wake"
      , [ Alcotest.test_case
            "submit_and_await resolve resumes directly without wake hook"
            `Quick
            test_resolve_with_live_resolver_does_not_fire_keeper_wake_hook
        ; Alcotest.test_case
            "submit_pending resolve fires the keeper wake hook"
            `Quick
            test_submit_pending_resolve_fires_keeper_wake_hook
        ] )
    ; ( "summary"
      , [ Alcotest.test_case
            "context summary survives include_input:true JSON paths"
            `Quick
            test_summary_survives_include_input_paths
        ; Alcotest.test_case
            "missing root switch marks summary failed"
            `Quick
            test_summary_worker_missing_root_switch_is_explicit_failure
        ] )
    ; ( "conversions"
      , [ Alcotest.test_case
            "pending_phase string conversions round-trip"
            `Quick
            test_pending_phase_conversions
        ] )
    ]
;;
