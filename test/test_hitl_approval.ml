module Types = Masc_domain

(** Tests for the HITL approval pipeline (#5907).

    Proves:
    1. Governance risk classification maps tool names to correct levels
    2. Governance threshold × risk level → correct approval decisions
    3. Approval queue: fiber suspension via Eio.Promise, resolution resumes
    4. Approval queue: stale entries expire with Reject
    5. Approval callback returns correct OAS decisions *)

module GP = Masc.Governance_pipeline
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module AQ = Masc.Keeper_approval_queue
module SDH = Server_dashboard_http
module KT = Keeper_types
module Mcp_eio = Masc.Mcp_server_eio
module Mcp_server = Masc.Mcp_server

let check = Alcotest.(check string)

let temp_dir () =
  let dir = Filename.temp_file "test_hitl_approval_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let meta_from_json json =
  let json =
    match json with
    | `Assoc fields when not (List.mem_assoc "tool_access" fields) ->
      `Assoc (("tool_access", `List []) :: fields)
    | _ -> json
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Ok m -> m
  | Error e -> Alcotest.fail ("meta parse failed: " ^ e)

let cleanup_dir dir =
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Sys.remove path
  in
  try rm_rf dir with _ -> ()

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  n_len = 0 || loop 0

let has_assoc_key key = function
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> false

let rec yield_until ?(attempts = 50) predicate =
  if predicate () || attempts <= 0 then ()
  else (
    Eio.Fiber.yield ();
    yield_until ~attempts:(attempts - 1) predicate)

let pending_id_for_keeper ~keeper_name =
  match AQ.list_pending_json () with
  | `List entries ->
    List.find_map
      (function
        | `Assoc kvs ->
          (match
             List.assoc_opt "keeper_name" kvs,
             List.assoc_opt "id" kvs
           with
           | Some (`String name), Some (`String id)
             when String.equal name keeper_name -> Some id
           | _ -> None)
        | _ -> None)
      entries
  | _ -> None

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.putenv key "")
    f

let audit_event_names ~base_path ~keeper_name =
  AQ.read_recent_audit ~base_path ~keeper_name ~n:10 ()
  |> List.map (fun json ->
         Yojson.Safe.Util.(json |> member "event" |> to_string))

let find_audit_event ~base_path ~keeper_name ~event_type =
  AQ.read_recent_audit ~base_path ~keeper_name ~n:10 ()
  |> List.find_opt (fun json ->
         Yojson.Safe.Util.(json |> member "event" |> to_string = event_type))

let test_first_cmd_token_uses_shared_words () =
  Alcotest.(check (option string))
    "quoted command basename preserved"
    (Some "gh cli")
    (AQ.For_testing.first_cmd_token {|"/tmp/bin/gh cli" pr list|});
  Alcotest.(check (option string))
    "malformed quote fails closed"
    None
    (AQ.For_testing.first_cmd_token {|"/tmp/bin/gh cli pr list|})

let test_approval_queue_failure_metric_labels_site () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "approval-failure-observe-test" in
  let site = "audit_append" in
  let labels = [ ("keeper", keeper_name); ("site", site) ] in
  let base_path = temp_dir () in
  let audit_dir =
    Filename.concat
      (Filename.concat base_path ".masc")
      "audit-approvals"
  in
  let before =
    Masc.Otel_metric_store.metric_value_or_zero
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_audit_store ();
      cleanup_dir base_path)
    (fun () ->
      AQ.For_testing.reset_audit_store ();
      AQ.audit_approval_event ~base_path ~event_type:"warmup"
        ~id:"audit-failure-warmup" ~keeper_name:(keeper_name ^ "-warmup")
        ~tool_name:"tool_search_files" ~risk_level:AQ.Medium ();
      cleanup_dir audit_dir;
      let oc = open_out_bin audit_dir in
      close_out oc;
  AQ.audit_approval_event ~base_path
    ~event_type:AQ.approval_audit_pending_event
        ~id:"audit-failure-path-test" ~keeper_name ~tool_name:"tool_search_files"
        ~risk_level:AQ.Medium ();
      let after =
        Masc.Otel_metric_store.metric_value_or_zero
          Keeper_metrics.(to_string ApprovalQueueFailures)
          ~labels
          ()
      in
      Alcotest.(check (float 0.0001)) "failure counter delta" 1.0
        (after -. before))

let with_test_config f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      f (Mcp_server.workspace_config state))

let with_eio_base_path f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let base_path = temp_dir () in
  AQ.For_testing.reset_audit_store ();
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_audit_store ();
      cleanup_dir base_path)
    (fun () -> f base_path)

let with_temp_masc_base f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let old_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let old_base_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  let base_path = temp_dir () in
  AQ.For_testing.reset_audit_store ();
  Unix.putenv "MASC_BASE_PATH" base_path;
  Unix.putenv "MASC_BASE_PATH_INPUT" base_path;
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_audit_store ();
      (match old_base with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> Unix.putenv "MASC_BASE_PATH" "");
      (match old_base_input with
       | Some value -> Unix.putenv "MASC_BASE_PATH_INPUT" value
       | None -> Unix.putenv "MASC_BASE_PATH_INPUT" "");
      cleanup_dir base_path)
    (fun () -> f base_path)

(* ── 1. Risk classification ──────────────────────────────── *)

let test_risk_classification_critical () =
  let tools = [
    ("tool_edit_file", GP.Critical);
    ("masc_force_reset", GP.Critical);
    ("keeper_destroy", GP.Critical);
  ] in
  List.iter (fun (tool_name, expected) ->
    let actual = GP.assess_risk ~tool_name ~input:(`Assoc []) in
    check
      (Printf.sprintf "%s → %s" tool_name (GP.risk_level_to_string expected))
      (GP.risk_level_to_string expected)
      (GP.risk_level_to_string actual)
  ) tools

let test_risk_classification_high () =
  let tools = [
    ("tool_write_file", GP.High);
    ("tool_edit_file", GP.High);
    ("masc_create_task", GP.High);
  ] in
  List.iter (fun (tool_name, expected) ->
    let actual = GP.assess_risk ~tool_name ~input:(`Assoc []) in
    let actual_int = GP.risk_level_to_int actual in
    let expected_int = GP.risk_level_to_int expected in
    Alcotest.(check bool)
      (Printf.sprintf "%s ≥ %s" tool_name (GP.risk_level_to_string expected))
      true
      (actual_int >= expected_int)
  ) tools

let test_risk_classification_low () =
  let tools = [
    ("masc_status", GP.Low);
    ("keeper_context_status", GP.Low);
    ("masc_board_list", GP.Low);
  ] in
  List.iter (fun (tool_name, expected) ->
    let actual = GP.assess_risk ~tool_name ~input:(`Assoc []) in
    check
      (Printf.sprintf "%s → %s" tool_name (GP.risk_level_to_string expected))
      (GP.risk_level_to_string expected)
      (GP.risk_level_to_string actual)
  ) tools

(* ── 2. Threshold decisions ──────────────────────────────── *)

let test_development_allows_all () =
  (* development: no confirmation needed for any risk level *)
  Alcotest.(check (option string))
    "development → None"
    None
    (Option.map GP.risk_level_to_string (GP.confirm_threshold "development"))

let test_paranoid_blocks_medium () =
  (* paranoid: confirmation from Medium upward *)
  match GP.confirm_threshold "paranoid" with
  | Some GP.Medium -> ()
  | Some other ->
    Alcotest.fail
      (Printf.sprintf "expected Medium, got %s" (GP.risk_level_to_string other))
  | None -> Alcotest.fail "expected Some Medium, got None"

let test_production_blocks_critical () =
  match GP.confirm_threshold "production" with
  | Some GP.Critical -> ()
  | Some other ->
    Alcotest.fail
      (Printf.sprintf "expected Critical, got %s" (GP.risk_level_to_string other))
  | None -> Alcotest.fail "expected Some Critical, got None"

let test_enterprise_blocks_high () =
  match GP.confirm_threshold "enterprise" with
  | Some GP.High -> ()
  | Some other ->
    Alcotest.fail
      (Printf.sprintf "expected High, got %s" (GP.risk_level_to_string other))
  | None -> Alcotest.fail "expected Some High, got None"

(* ── 3. Approval queue: Eio.Promise-based suspend/resume ── *)

let test_approval_queue_submit_and_resolve () =
  Eio_main.run @@ fun _env ->
  (* Simulate: agent fiber submits, operator fiber resolves *)
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  Eio.Switch.run @@ fun sw ->
  let result = ref None in
  (* Agent fiber: submit and await (will block until resolved) *)
  Eio.Fiber.fork ~sw (fun () ->
    let decision =
      AQ.submit_and_await
        ~keeper_name:"test-keeper"
        ~tool_name:"tool_edit_file"
        ~input:(`Assoc [("path", `String "/dangerous")])
        ~risk_level:AQ.Critical
        ~base_path
        ()
    in
    result := Some decision
  );
  (* Give agent fiber time to submit *)
  Eio.Fiber.yield ();
  (* Verify pending *)
  let pending_count = AQ.pending_count () in
  Alcotest.(check bool) "1 pending" true (pending_count >= 1);
  (* Get pending list to find ID *)
  let pending_json = AQ.list_pending_json () in
  let entries = match pending_json with
    | `List entries -> entries
    | _ -> Alcotest.fail "expected list"
  in
  Alcotest.(check bool) "has entries" true (List.length entries >= 1);
  let id = match List.hd entries with
    | `Assoc kvs ->
      (match List.assoc_opt "id" kvs with
       | Some (`String id) -> id
       | _ -> Alcotest.fail "no id field")
    | _ -> Alcotest.fail "bad entry"
  in
  (* Operator resolves: approve *)
  (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
   | Ok () -> ()
   | Error err -> Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
  (* Agent fiber should resume *)
  Eio.Fiber.yield ();
  match !result with
  | Some Agent_sdk.Hooks.Approve -> ()
  | Some (Agent_sdk.Hooks.Reject r) ->
    Alcotest.fail ("expected Approve, got Reject: " ^ r)
  | Some (Agent_sdk.Hooks.Edit _) ->
    Alcotest.fail "expected Approve, got Edit"
  | None -> Alcotest.fail "agent fiber did not resume")

let test_approval_queue_reject () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  Eio.Switch.run @@ fun sw ->
  let result = ref None in
  Eio.Fiber.fork ~sw (fun () ->
    let decision =
      AQ.submit_and_await
        ~keeper_name:"test-keeper"
        ~tool_name:"masc_force_reset"
        ~input:(`Assoc [])
        ~risk_level:AQ.Critical
        ~base_path
        ()
    in
    result := Some decision
  );
  Eio.Fiber.yield ();
  let pending_json = AQ.list_pending_json () in
  let id = match pending_json with
    | `List (`Assoc kvs :: _) ->
      (match List.assoc_opt "id" kvs with
       | Some (`String id) -> id
       | _ -> "")
    | _ -> ""
  in
  (match AQ.resolve ~id ~decision:(Agent_sdk.Hooks.Reject "too dangerous") with
   | Ok () -> ()
   | Error err -> Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
  Eio.Fiber.yield ();
  match !result with
  | Some (Agent_sdk.Hooks.Reject reason) ->
    Alcotest.(check bool) "reason contains text" true
      (String.length reason > 0)
  | _ -> Alcotest.fail "expected Reject")

let test_approval_queue_expire_stale () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  Eio.Switch.run @@ fun sw ->
  let result = ref None in
  Eio.Fiber.fork ~sw (fun () ->
    let decision =
      AQ.submit_and_await
        ~keeper_name:"test-keeper"
        ~tool_name:"masc_dangerous_tool"
        ~input:(`Assoc [])
        ~risk_level:AQ.High
        ~base_path
        ()
    in
    result := Some decision
  );
  Eio.Fiber.yield ();
  (* Expire with max_wait_s=0 → everything past the threshold is stale.
     [High] (and below) is auto-expired by the periodic janitor. *)
  AQ.expire_stale ~max_wait_s:0.0;
  Eio.Fiber.yield ();
  match !result with
  | Some (Agent_sdk.Hooks.Reject reason) ->
    Alcotest.(check bool) "timeout reason" true
      (String.starts_with ~prefix:"approval timed out" reason)
  | _ -> Alcotest.fail "expected Reject from timeout")

let test_approval_queue_expire_skips_critical () =
  (* [Critical] entries originate from indefinite-wait operator gates
     ([keeper_continue_after_reconcile] etc.). Auto-rejection would
     create a 30-min expire / re-enqueue cycle and silently push the
     keeper into a permanent paused state. The janitor must skip them. *)
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  let resolution = ref None in
  let id =
    AQ.submit_pending
      ~keeper_name:"test-keeper-critical"
      ~tool_name:"keeper_continue_after_reconcile"
      ~input:(`Assoc [])
      ~base_path
      ~risk_level:AQ.Critical
      ~on_resolution:(fun decision -> resolution := Some decision)
      ()
  in
  let pending_before = AQ.pending_count_for_keeper ~keeper_name:"test-keeper-critical" in
  Alcotest.(check int) "Critical entry enqueued" 1 pending_before;
  (* Aggressive max_wait_s=0: would expire High/Medium/Low immediately. *)
  AQ.expire_stale ~max_wait_s:0.0;
  let pending_after = AQ.pending_count_for_keeper ~keeper_name:"test-keeper-critical" in
  Alcotest.(check int) "Critical NOT expired by janitor" 1 pending_after;
  Alcotest.(check (option string)) "on_resolution NOT called" None
    (match !resolution with
     | None -> None
     | Some _ -> Some "resolved");
  (* Cleanup: manually resolve so subsequent tests don't see stray state. *)
  match AQ.resolve ~id ~decision:(Agent_sdk.Hooks.Reject "test cleanup") with
  | Ok () | Error _ -> ())

let test_submit_and_await_clock_timeout_skips_critical () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  Eio.Switch.run @@ fun sw ->
  let keeper_name = "critical-clock-timeout-test" in
  let result = ref None in
  Eio.Fiber.fork ~sw (fun () ->
    let decision =
      AQ.submit_and_await
        ~keeper_name
        ~tool_name:"keeper_continue_after_reconcile"
        ~input:(`Assoc [])
        ~risk_level:AQ.Critical
        ~base_path
        ~clock
        ~timeout_s:0.01
        ()
    in
    result := Some decision);
  yield_until (fun () -> Option.is_some (pending_id_for_keeper ~keeper_name));
  Eio.Time.sleep clock 0.03;
  Alcotest.(check bool)
    "Critical approval still waits past submit timeout"
    true
    (Option.is_none !result);
  let id =
    match pending_id_for_keeper ~keeper_name with
    | Some id -> id
    | None -> Alcotest.fail "Critical approval was auto-removed"
  in
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
  | None -> Alcotest.fail "Critical approval did not resume")

let test_submit_and_await_critical_escalates_then_waits () =
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
  let keeper_name = "critical-escalation-test" in
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
  Eio.Time.sleep clock 0.03;
  yield_until (fun () ->
    List.exists
      (String.equal "approval_escalated")
      (audit_event_names ~base_path ~keeper_name));
  Alcotest.(check bool)
    "Critical escalation audit recorded"
    true
    (List.exists
       (String.equal "approval_escalated")
       (audit_event_names ~base_path ~keeper_name));
  let escalation_event =
    match find_audit_event ~base_path ~keeper_name ~event_type:"approval_escalated" with
    | Some json -> json
    | None -> Alcotest.fail "expected Critical escalation audit row"
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "Critical escalation is not a terminal decision"
    ""
    (escalation_event |> member "decision" |> to_string);
  Alcotest.(check bool)
    "Critical escalation has no decision kind"
    true
    (escalation_event |> member "decision_kind" = `Null);
  Alcotest.(check bool)
    "Critical escalation has no decision reason"
    true
    (escalation_event |> member "decision_reason" = `Null);
  Alcotest.(check string)
    "Critical escalation disposition"
    "escalated"
    (escalation_event |> member "disposition" |> to_string);
  Alcotest.(check string)
    "Critical escalation disposition reason"
    "critical approval escalated — operator must decide"
    (escalation_event |> member "disposition_reason" |> to_string);
  Alcotest.(check bool)
    "Critical escalation does not auto-resolve"
    true
    (Option.is_none !result);
  let id =
    match pending_id_for_keeper ~keeper_name with
    | Some id -> id
    | None -> Alcotest.fail "Critical approval was removed after escalation"
  in
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

let test_submit_and_await_clock_returns_manual_decision () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  Eio.Switch.run @@ fun sw ->
  let keeper_name = "medium-clock-manual-test" in
  let result = ref None in
  Eio.Fiber.fork ~sw (fun () ->
    let decision =
      AQ.submit_and_await
        ~keeper_name
        ~tool_name:"tool_search_files"
        ~input:(`Assoc [ ("op", `String "write") ])
        ~risk_level:AQ.Medium
        ~base_path
        ~clock
        ~timeout_s:1.0
        ()
    in
    result := Some decision);
  yield_until (fun () -> Option.is_some (pending_id_for_keeper ~keeper_name));
  let id =
    match pending_id_for_keeper ~keeper_name with
    | Some id -> id
    | None -> Alcotest.fail "medium approval was not queued"
  in
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
  | None -> Alcotest.fail "manual approval did not resume")

let test_approval_resolve_nonexistent () =
  Eio_main.run @@ fun _env ->
  match AQ.resolve ~id:"nonexistent_id" ~decision:Agent_sdk.Hooks.Approve with
  | Error (AQ.Not_found _ as err) ->
    Alcotest.(check bool) "error message" true
      (String.length (AQ.resolve_error_to_string err) > 0)
  | Error (AQ.Already_resolved _) ->
    Alcotest.fail "expected Not_found, got Already_resolved"
  | Ok () -> Alcotest.fail "expected error for nonexistent id"

let test_approval_queue_cancel_cleans_up () =
  Eio_main.run @@ fun _env ->
  (* Simulate: agent fiber is cancelled (Switch closes) while awaiting.
     The pending entry must be cleaned up from the hashtbl. (#5949) *)
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  let initial_count = AQ.pending_count () in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       let _decision =
         AQ.submit_and_await
           ~keeper_name:"cancel-test"
           ~tool_name:"masc_dangerous"
           ~input:(`Assoc [])
           ~risk_level:AQ.Critical
           ~base_path
           ()
       in
       ());
     Eio.Fiber.yield ();
     (* Cancel the switch — this cancels the awaiting fiber *)
     Eio.Switch.fail sw (Failure "simulated shutdown")
   with Failure _ -> ());
  (* After cancellation, the pending entry should be cleaned up *)
  let final_count = AQ.pending_count () in
  Alcotest.(check int) "no orphan entries" initial_count final_count)

let test_approval_queue_cancel_records_terminal_audit () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  let keeper_name = "cancel-audit-test" in
  AQ.For_testing.reset_audit_store ();
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_audit_store ();
      cleanup_dir base_path)
    (fun () ->
      let initial_count = AQ.pending_count () in
      (try
         Eio.Switch.run @@ fun sw ->
         Eio.Fiber.fork ~sw (fun () ->
           ignore
             (AQ.submit_and_await
                ~keeper_name
                ~tool_name:"tool_edit_file"
                ~input:(`Assoc [ ("path", `String "lib/example.ml") ])
                ~risk_level:AQ.Critical
                ~base_path
                ()));
         yield_until (fun () ->
           AQ.pending_count_for_keeper ~keeper_name = 1);
         Eio.Switch.fail sw (Failure "simulated shutdown")
       with Failure _ -> ());
      Alcotest.(check int) "no orphan entries" initial_count (AQ.pending_count ());
      match AQ.read_recent_audit ~base_path ~keeper_name ~n:1 () with
      | latest :: _ ->
        let open Yojson.Safe.Util in
        Alcotest.(check string) "latest event is terminal" "cancelled"
          (latest |> member "event" |> to_string);
        Alcotest.(check bool) "decision records cancellation" true
          (contains_substring
             (latest |> member "decision" |> to_string)
             "approval await cancelled")
      | [] -> Alcotest.fail "expected cancellation audit row")

let test_background_pending_callback_and_keeper_lookup () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  let initial_count = AQ.pending_count () in
  let callback_result = ref None in
  let id =
    AQ.submit_pending
      ~keeper_name:"gate-keeper"
      ~tool_name:"keeper_continue_after_partial_commit"
      ~input:(`Assoc [("kind", `String "continue_gate_required")])
      ~risk_level:AQ.Critical
      ~base_path
      ~on_resolution:(fun decision -> callback_result := Some decision)
      ()
  in
  Alcotest.(check bool) "keeper has pending approval" true
    (AQ.has_pending_for_keeper ~keeper_name:"gate-keeper");
  Alcotest.(check int) "background entry added"
    (initial_count + 1) (AQ.pending_count ());
  (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
   | Ok () -> ()
   | Error err -> Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
  Alcotest.(check bool) "keeper pending cleared" false
    (AQ.has_pending_for_keeper ~keeper_name:"gate-keeper");
  Alcotest.(check int) "background entry removed"
    initial_count (AQ.pending_count ());
  match !callback_result with
  | Some Agent_sdk.Hooks.Approve -> ()
  | Some _ -> Alcotest.fail "expected approve callback"
  | None -> Alcotest.fail "expected callback to fire")

let test_background_pending_reuses_existing_entry () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  let initial_count = AQ.pending_count () in
  let first_callback = ref None in
  let second_callback = ref None in
  let id1 =
    AQ.submit_pending
      ~keeper_name:"gate-keeper"
      ~tool_name:"keeper_continue_after_partial_commit"
      ~input:(`Assoc [("kind", `String "continue_gate_required")])
      ~risk_level:AQ.Critical
      ~base_path
      ~on_resolution:(fun decision -> first_callback := Some decision)
      ()
  in
  let after_first = AQ.pending_count () in
  let id2 =
    AQ.submit_pending
      ~keeper_name:"gate-keeper"
      ~tool_name:"keeper_continue_after_partial_commit"
      ~input:(`Assoc [("kind", `String "continue_gate_required")])
      ~risk_level:AQ.Critical
      ~base_path
      ~on_resolution:(fun decision -> second_callback := Some decision)
      ()
  in
  Alcotest.(check string) "existing pending id reused" id1 id2;
  Alcotest.(check int) "only one entry created"
    (initial_count + 1) after_first;
  Alcotest.(check int) "second submit does not grow queue"
    after_first (AQ.pending_count ());
  (match AQ.resolve ~id:id1 ~decision:Agent_sdk.Hooks.Approve with
   | Ok () -> ()
   | Error err -> Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
  Alcotest.(check bool) "first callback fired" true
    (match !first_callback with Some Agent_sdk.Hooks.Approve -> true | _ -> false);
  Alcotest.(check bool) "second callback not attached to duplicate submit" true
    (Option.is_none !second_callback))

let test_background_pending_distinct_inputs_do_not_reuse_entry () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  let initial_count = AQ.pending_count () in
  let callback_result = ref [] in
  let id1 =
    AQ.submit_pending
      ~keeper_name:"gate-keeper"
      ~tool_name:"tool_execute"
      ~input:
        (`Assoc
          [ "executable", `String "git"
          ; "argv", `List [ `String "status"; `String "--short" ]
          ])
      ~risk_level:AQ.Medium
      ~base_path
      ~on_resolution:(fun decision -> callback_result := decision :: !callback_result)
      ()
  in
  let id2 =
    AQ.submit_pending
      ~keeper_name:"gate-keeper"
      ~tool_name:"tool_execute"
      ~input:
        (`Assoc
          [ "executable", `String "git"
          ; "argv", `List [ `String "log"; `String "--oneline"; `String "-1" ]
          ])
      ~risk_level:AQ.High
      ~base_path
      ~on_resolution:(fun decision -> callback_result := decision :: !callback_result)
      ()
  in
  Alcotest.(check bool) "distinct pending ids" true (id1 <> id2);
  Alcotest.(check int) "two entries created"
    (initial_count + 2) (AQ.pending_count ());
  ignore (AQ.resolve ~id:id1 ~decision:Agent_sdk.Hooks.Approve);
  ignore (AQ.resolve ~id:id2 ~decision:(Agent_sdk.Hooks.Reject "cleanup"));
  Alcotest.(check int) "cleanup restores count"
    initial_count (AQ.pending_count ()))

let test_approval_queue_get_pending_detail () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  let initial_count = AQ.pending_count () in
  let callback_result = ref None in
  let input =
    `Assoc [
      ("path", `String "/tmp/danger");
      ("reason", `String "operator needs full input");
      ("nested", `Assoc [("mode", `String "detail")]);
    ]
  in
  let id =
    AQ.submit_pending
      ~keeper_name:"detail-keeper"
      ~tool_name:"tool_edit_file"
      ~base_path
      ~input
      ~risk_level:AQ.Critical
      ~turn_id:7
      ~task_id:"task-runtime-trust"
      ~goal_id:"goal-runtime-trust"
      ~goal_ids:[ "goal-runtime-trust"; "goal-mid" ]
      ~runtime_contract:(`Assoc [ ("backend", `String "docker") ])
      ~on_resolution:(fun decision -> callback_result := Some decision)
      ()
  in
  let open Yojson.Safe.Util in
  let detail =
    match AQ.get_pending_json ~id with
    | Some json -> json
    | None -> Alcotest.fail "expected pending approval detail"
  in
  Alcotest.(check string) "detail id" id (detail |> member "id" |> to_string);
  Alcotest.(check string) "detail keeper" "detail-keeper"
    (detail |> member "keeper_name" |> to_string);
  Alcotest.(check string) "detail tool" "tool_edit_file"
    (detail |> member "tool_name" |> to_string);
  Alcotest.(check string) "detail action key" "tool:tool_edit_file"
    (detail |> member "action_key" |> to_string);
  Alcotest.(check string) "detail sandbox target" "docker"
    (detail |> member "sandbox_target" |> to_string);
  Alcotest.(check string) "detail risk" "critical"
    (detail |> member "risk_level" |> to_string);
  Alcotest.(check int) "detail turn id" 7
    (detail |> member "turn_id" |> to_int);
  Alcotest.(check string) "detail task id" "task-runtime-trust"
    (detail |> member "task_id" |> to_string);
  Alcotest.(check string) "detail goal id" "goal-runtime-trust"
    (detail |> member "goal_id" |> to_string);
  Alcotest.(check (list string)) "detail goal ids"
    [ "goal-runtime-trust"; "goal-mid" ]
    (detail |> member "goal_ids" |> to_list |> List.map to_string);
  Alcotest.(check string) "detail runtime contract backend" "docker"
    (detail |> member "runtime_contract" |> member "backend" |> to_string);
  Alcotest.(check string) "detail includes full input"
    (Yojson.Safe.to_string input)
    (detail |> member "input" |> Yojson.Safe.to_string);
  Alcotest.(check bool) "detail includes preview" true
    (String.length (detail |> member "input_preview" |> to_string) > 0);
  Alcotest.(check bool) "missing detail returns none" true
    (Option.is_none (AQ.get_pending_json ~id:"missing-approval"));
  (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
   | Ok () -> ()
   | Error err -> Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
  Alcotest.(check bool) "callback fired" true
    (match !callback_result with Some Agent_sdk.Hooks.Approve -> true | _ -> false);
  Alcotest.(check int) "entry removed"
    initial_count (AQ.pending_count ()))

let test_approval_queue_keeps_sandbox_backend_out_of_runtime_contract () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  let runtime_contract =
    Masc.Keeper_runtime_contract.runtime_contract_json_from_fields
      ~keeper_name:"redacted-contract-keeper"
      ~sandbox_profile:"docker"
      ~network_mode:"none"
      ()
  in
  Alcotest.(check bool)
    "keeper-visible runtime_contract has no backend"
    false
    (has_assoc_key "backend" runtime_contract);
  Alcotest.(check bool)
    "keeper-visible runtime_contract has no sandbox_profile"
    false
    (has_assoc_key "sandbox_profile" runtime_contract);
  let id =
    AQ.submit_pending
      ~keeper_name:"redacted-contract-keeper"
      ~tool_name:"tool_execute"
      ~input:(`Assoc [ ("cmd", `String "git status") ])
      ~risk_level:AQ.Medium
      ~sandbox_target:"docker"
      ~sandbox_profile:"docker"
      ~backend:"docker"
      ~runtime_contract
      ~base_path
      ~on_resolution:(fun _ -> ())
      ()
  in
  let open Yojson.Safe.Util in
  Fun.protect
    ~finally:(fun () ->
      ignore (AQ.resolve ~id ~decision:(Agent_sdk.Hooks.Reject "cleanup")))
    (fun () ->
      let detail =
        match AQ.get_pending_json ~id with
        | Some json -> json
        | None -> Alcotest.fail "expected pending approval detail"
      in
      Alcotest.(check string) "operator sandbox target" "docker"
        (detail |> member "sandbox_target" |> to_string);
      let detail_contract = detail |> member "runtime_contract" in
      Alcotest.(check bool)
        "detail runtime_contract keeps backend redacted"
        false
        (has_assoc_key "backend" detail_contract);
      Alcotest.(check bool)
        "detail runtime_contract keeps sandbox_profile redacted"
        false
        (has_assoc_key "sandbox_profile" detail_contract)))

let test_resolve_with_policy_remembers_medium_allow () =
  with_eio_base_path @@ fun base_path ->
      let id =
        AQ.submit_pending
          ~base_path
          ~keeper_name:"remember-keeper"
          ~tool_name:"masc_transition"
          ~input:(`Assoc [ ("action", `String "claim") ])
          ~risk_level:AQ.Medium
          ~on_resolution:(fun _ -> ())
          ()
      in
      match
        AQ.resolve_with_policy ~base_path ~id
          ~decision:Agent_sdk.Hooks.Approve ~remember_rule:true ()
      with
      | Ok { remembered_rule = Some _ } ->
          let open Yojson.Safe.Util in
          let summary =
            AQ.policy_summary_json ~base_path ~keeper_name:"remember-keeper"
          in
          Alcotest.(check int) "allow rules persisted" 1
            (summary |> member "allow_rules" |> to_int)
      | Ok { remembered_rule = None } ->
          Alcotest.fail "expected remembered_rule for medium allow"
      | Error err ->
          Alcotest.fail ("resolve_with_policy failed: " ^ AQ.resolve_error_to_string err)

let test_resolve_with_policy_does_not_remember_high_allow () =
  with_eio_base_path @@ fun base_path ->
      let id =
        AQ.submit_pending
          ~base_path
          ~keeper_name:"remember-keeper"
          ~tool_name:"tool_edit_file"
          ~input:(`Assoc [("path", `String "lib/example.ml")])
          ~risk_level:AQ.High
          ~on_resolution:(fun _ -> ())
          ()
      in
      match
        AQ.resolve_with_policy ~base_path ~id
          ~decision:Agent_sdk.Hooks.Approve ~remember_rule:true ()
      with
      | Ok { remembered_rule = None } ->
          let open Yojson.Safe.Util in
          let summary =
            AQ.policy_summary_json ~base_path ~keeper_name:"remember-keeper"
          in
          Alcotest.(check int) "no persisted rules for high allow" 0
            (summary |> member "persisted_rules" |> to_int)
      | Ok { remembered_rule = Some _ } ->
          Alcotest.fail "high-risk allow should not be remembered"
      | Error err ->
          Alcotest.fail ("resolve_with_policy failed: " ^ AQ.resolve_error_to_string err)

let test_runtime_contract_policy_uses_workspace_base_path () =
  let env_base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir env_base)
    (fun () ->
      with_test_config @@ fun config ->
      AQ.For_testing.reset_audit_store ();
      Fun.protect
        ~finally:AQ.For_testing.reset_audit_store
        (fun () ->
          with_env "MASC_BASE_PATH" env_base @@ fun () ->
          with_env "MASC_BASE_PATH_INPUT" env_base @@ fun () ->
          let keeper_name = "runtime-contract-policy-keeper" in
          let id =
            AQ.submit_pending
              ~base_path:config.base_path
              ~keeper_name
              ~tool_name:"masc_transition"
              ~input:(`Assoc [ ("action", `String "claim") ])
              ~risk_level:AQ.Medium
              ~on_resolution:(fun _ -> ())
              ()
          in
          (match
             AQ.resolve_with_policy ~base_path:config.base_path ~id
               ~decision:Agent_sdk.Hooks.Approve ~remember_rule:true ()
           with
           | Ok { remembered_rule = Some _ } -> ()
           | Ok { remembered_rule = None } ->
               Alcotest.fail "expected remembered workspace approval rule"
           | Error err ->
               Alcotest.fail
                 ("resolve_with_policy failed: "
                  ^ AQ.resolve_error_to_string err));
          let meta =
            meta_from_json
              (`Assoc
                [
                  ("name", `String keeper_name);
                  ("trace_id", `String "runtime-contract-policy-trace");
                  ("sandbox_profile", `String "docker");
                  ("network_mode", `String "inherit");
                ])
          in
          let runtime_contract =
            Masc.Keeper_runtime_contract.runtime_contract_json ~config meta
          in
          let open Yojson.Safe.Util in
          let policy =
            runtime_contract |> member "approval_policy_effective"
          in
          Alcotest.(check int) "workspace policy allow rule"
            1
            (policy |> member "allow_rules" |> to_int);
          let env_policy =
            AQ.policy_summary_json ~base_path:env_base ~keeper_name
          in
          Alcotest.(check int) "env fallback has no allow rule"
            0
            (env_policy |> member "allow_rules" |> to_int)))

let test_dashboard_resolve_and_delete_rules_use_workspace_base_path () =
  let env_base = temp_dir () in
  let workspace_base = temp_dir () in
  let old_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let old_base_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  AQ.For_testing.reset_audit_store ();
  Unix.putenv "MASC_BASE_PATH" env_base;
  Unix.putenv "MASC_BASE_PATH_INPUT" env_base;
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_audit_store ();
      (match old_base with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> Unix.putenv "MASC_BASE_PATH" "");
      (match old_base_input with
       | Some value -> Unix.putenv "MASC_BASE_PATH_INPUT" value
       | None -> Unix.putenv "MASC_BASE_PATH_INPUT" "");
      cleanup_dir env_base;
      cleanup_dir workspace_base)
    (fun () ->
      let id =
        AQ.submit_pending
          ~keeper_name:"dashboard-workspace-keeper"
          ~tool_name:"masc_transition"
          ~input:
            (`Assoc
              [
                ("action", `String "claim");
                ("task_id", `String "task-workspace");
              ])
          ~risk_level:AQ.Medium
          ~base_path:workspace_base
          ~on_resolution:(fun _ -> ())
          ()
      in
      let resolve_args =
        `Assoc
          [
            ("id", `String id);
            ("decision", `String "approve");
            ("remember_rule", `Bool true);
          ]
      in
      let rule_id =
        match
          SDH.dashboard_governance_approval_resolve_http_json ~base_path:workspace_base
            ~args:resolve_args
        with
        | Ok json ->
            let open Yojson.Safe.Util in
            json |> member "rule_id" |> to_string
        | Error err ->
            Alcotest.fail
              ("dashboard resolve failed: "
              ^ SDH.approval_resolve_http_error_to_string err)
      in
      Alcotest.(check int) "workspace rule persisted" 1
        (List.length (AQ.list_rules ~base_path:workspace_base ()));
      Alcotest.(check int) "env fallback has no rule" 0
        (List.length (AQ.list_rules ~base_path:env_base ()));
      (match
         SDH.dashboard_governance_approval_rule_delete_http_json
           ~base_path:workspace_base
           ~args:(`Assoc [ ("id", `String rule_id) ])
       with
       | Ok _ -> ()
       | Error message ->
           Alcotest.fail ("dashboard rule delete failed: " ^ message));
      Alcotest.(check int) "workspace rule deleted" 0
        (List.length (AQ.list_rules ~base_path:workspace_base ()));
      Alcotest.(check int) "env fallback still empty" 0
        (List.length (AQ.list_rules ~base_path:env_base ())))

let test_submit_pending_audit_uses_workspace_base_path () =
  let env_base = temp_dir () in
  let workspace_base = temp_dir () in
  let old_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let old_base_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  let keeper_name = "approval-workspace-audit-keeper" in
  AQ.For_testing.reset_audit_store ();
  Unix.putenv "MASC_BASE_PATH" env_base;
  Unix.putenv "MASC_BASE_PATH_INPUT" env_base;
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_audit_store ();
      (match old_base with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> Unix.putenv "MASC_BASE_PATH" "");
      (match old_base_input with
       | Some value -> Unix.putenv "MASC_BASE_PATH_INPUT" value
       | None -> Unix.putenv "MASC_BASE_PATH_INPUT" "");
      cleanup_dir env_base;
      cleanup_dir workspace_base)
    (fun () ->
      ignore
        (AQ.submit_pending
           ~keeper_name
           ~tool_name:"masc_transition"
           ~input:
             (`Assoc
               [
                 ("action", `String "claim");
                 ("task_id", `String "task-workspace-audit");
               ])
           ~risk_level:AQ.High
           ~base_path:workspace_base
           ~on_resolution:(fun _ -> ())
           ());
      AQ.expire_stale ~max_wait_s:(-1.0);
      let workspace_events = audit_event_names ~base_path:workspace_base ~keeper_name in
      let env_events = audit_event_names ~base_path:env_base ~keeper_name in
      Alcotest.(check bool) "workspace audit has pending" true
        (List.exists (String.equal "pending") workspace_events);
      Alcotest.(check bool) "workspace audit has expired" true
        (List.exists (String.equal "expired") workspace_events);
      Alcotest.(check (list string)) "env fallback has no workspace audit" []
        env_events)

(* ── 4. Approval callback integration ────────────────────── *)

let test_callback_approves_low_risk () =
  (* development level: no confirmation needed *)
  with_test_config @@ fun config ->
  let cb = GP.to_oas_approval_callback
    ~config ~governance_level:"development" ~keeper_name:"test" () in
  let decision = cb ~tool_name:"masc_status" ~input:(`Assoc []) in
  match decision with
  | Agent_sdk.Hooks.Approve -> ()
  | Agent_sdk.Hooks.Reject r ->
    Alcotest.fail ("expected Approve for low-risk tool, got Reject: " ^ r)
  | _ -> Alcotest.fail "unexpected decision"

let test_callback_production_tool_edit_file_requires_approval () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let initial_pending = AQ.pending_count () in
  let result = ref None in
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let config = (Mcp_server.workspace_config state) in
  Eio.Fiber.fork ~sw (fun () ->
    let cb =
      GP.to_oas_approval_callback
        ~config ~governance_level:"production" ~keeper_name:"test" () in
    let decision =
      cb
        ~tool_name:"tool_edit_file"
        ~input:(`Assoc [
          ("path", `String "lib/example.ml");
          ("content", `String "let x = 1\n");
        ])
    in
    result := Some decision
  );
  yield_until (fun () -> AQ.pending_count () = initial_pending + 1);
  Alcotest.(check int) "one pending approval"
    (initial_pending + 1) (AQ.pending_count ());
  let pending_json = AQ.list_pending_json () in
  let id =
    match pending_json with
    | `List (`Assoc kvs :: _) ->
      (match List.assoc_opt "id" kvs with
       | Some (`String id) -> id
       | _ -> Alcotest.fail "missing approval id")
    | _ -> Alcotest.fail "expected pending approval entry"
  in
  (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
   | Ok () -> ()
   | Error err -> Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
  yield_until (fun () -> Option.is_some !result);
  match !result with
  | Some Agent_sdk.Hooks.Approve -> ()
  | Some _ -> Alcotest.fail "expected Approve after operator resolution"
  | None -> Alcotest.fail "keeper write callback did not suspend for approval")

let test_callback_production_claimed_worktree_write_auto_approved () =
  with_test_config @@ fun config ->
  let keeper_name = "sandbox-writer" in
  let meta =
    meta_from_json
      (`Assoc
        [
          ("name", `String keeper_name);
          ("agent_name", `String ("keeper-" ^ keeper_name ^ "-agent"));
          ("trace_id", `String "sandbox-write-trace");
          ("sandbox_profile", `String "docker");
          ("network_mode", `String "inherit");
          ("current_task_id", `String "task-210");
          ("always_approve", `Bool true);
        ])
  in
  let pending_before = AQ.pending_count () in
  let cb =
    GP.to_oas_approval_callback
      ~config
      ~governance_level:"production"
      ~keeper_name
      ~meta
      ()
  in
  let decision =
    cb
      ~tool_name:"Write"
      ~input:
        (`Assoc
          [
            ( "file_path",
              `String
                "repos/masc/.worktrees/keeper-sandbox-writer-task-210/lib/example.ml"
            );
            ("content", `String "let x = 1\n");
          ])
  in
  match decision with
  | Agent_sdk.Hooks.Approve ->
    Alcotest.(check int)
      "claimed sandbox worktree write does not enqueue approval"
      pending_before
      (AQ.pending_count ())
  | Agent_sdk.Hooks.Reject r ->
    Alcotest.fail
      ("expected Approve for claimed sandbox worktree write, got Reject: " ^ r)
  | _ -> Alcotest.fail "unexpected decision"

let test_callback_production_worktree_prepare_requires_approval () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let initial_pending = AQ.pending_count () in
  let result = ref None in
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let config = (Mcp_server.workspace_config state) in
      Eio.Fiber.fork ~sw (fun () ->
        let cb =
          GP.to_oas_approval_callback
            ~config ~governance_level:"production" ~keeper_name:"test" ()
        in
        let decision =
          cb
            ~tool_name:"tool_execute"
            ~input:
              (`Assoc
                [ ("task_id", `String "task-187"); ("repo_name", `String "masc") ])
        in
        result := Some decision);
      yield_until (fun () -> AQ.pending_count () = initial_pending + 1);
      Alcotest.(check int)
        "worktree preparation requires approval"
        (initial_pending + 1)
        (AQ.pending_count ());
      let id =
        match AQ.list_pending_json () with
        | `List (`Assoc kvs :: _) ->
          (match List.assoc_opt "id" kvs with
           | Some (`String id) -> id
           | _ -> Alcotest.fail "missing approval id")
        | _ -> Alcotest.fail "expected pending approval entry"
      in
      (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
       | Ok () -> ()
       | Error err -> Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
      yield_until (fun () -> Option.is_some !result);
      match !result with
      | Some Agent_sdk.Hooks.Approve -> ()
      | Some _ -> Alcotest.fail "expected Approve after operator resolution"
      | None -> Alcotest.fail "worktree preparation callback did not suspend for approval")

let test_callback_paranoid_medium_risk_uses_remembered_policy () =
  with_eio_base_path @@ fun base_path ->
      let id =
        AQ.submit_pending
          ~base_path
          ~keeper_name:"remember-keeper"
          ~tool_name:"masc_transition"
          ~input:(`Assoc [ ("action", `String "claim") ])
          ~risk_level:AQ.Medium
          ~on_resolution:(fun _ -> ())
          ()
      in
      (match
         AQ.resolve_with_policy ~base_path ~id
           ~decision:Agent_sdk.Hooks.Approve ~remember_rule:true ()
       with
       | Ok { remembered_rule = Some _ } -> ()
       | Ok { remembered_rule = None } ->
           Alcotest.fail "expected medium allow to be remembered"
       | Error err ->
           Alcotest.fail
             ("resolve_with_policy failed: " ^ AQ.resolve_error_to_string err));
      let pending_before = AQ.pending_count () in
      let config = Masc.Workspace.default_config base_path in
      let cb =
        GP.to_oas_approval_callback
          ~governance_level:"paranoid" ~keeper_name:"remember-keeper"
          ~config ()
      in
      let decision =
        cb
          ~tool_name:"masc_transition"
          ~input:(`Assoc [ ("action", `String "claim") ])
      in
      match decision with
      | Agent_sdk.Hooks.Approve ->
          Alcotest.(check int) "remembered policy bypasses queue"
            pending_before (AQ.pending_count ())
      | Agent_sdk.Hooks.Reject reason ->
          Alcotest.fail ("expected remembered approve, got reject: " ^ reason)
      | Agent_sdk.Hooks.Edit _ ->
          Alcotest.fail "expected remembered approve, got edit"

let test_callback_always_approve_bypasses_threshold () =
  with_test_config @@ fun config ->
  let meta =
    meta_from_json
      (`Assoc [
        ("name", `String "test-keeper");
        ("trace_id", `String "test-trace");
        ("sandbox_profile", `String "docker");
        ("network_mode", `String "inherit");
        ("always_approve", `Bool true);
      ])
  in
  let cb =
    GP.to_oas_approval_callback
      ~config ~governance_level:"production" ~keeper_name:"test-keeper" ~meta ()
  in
  let decision =
    cb ~tool_name:"masc_create_task"
      ~input:(`Assoc [("title", `String "test")])
  in
  match decision with
  | Agent_sdk.Hooks.Approve -> ()
  | Agent_sdk.Hooks.Reject r ->
    Alcotest.fail ("expected Approve with always_approve, got Reject: " ^ r)
  | _ -> Alcotest.fail "unexpected decision"

let test_callback_typed_last_blocker_overrides_always_approve () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let keeper_name = "typed-blocked-keeper" in
  let initial_pending = AQ.pending_count () in
  let result = ref None in
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let config = Mcp_server.workspace_config state in
      let meta =
        let base =
          meta_from_json
            (`Assoc
              [
                ("name", `String keeper_name);
                ("agent_name", `String ("keeper-" ^ keeper_name ^ "-agent"));
                ("trace_id", `String "runtime-blocked-trace");
                ("sandbox_profile", `String "docker");
                ("network_mode", `String "inherit");
                ("always_approve", `Bool true);
              ])
        in
        let blocker =
          let open Masc.Keeper_meta_contract in
          blocker_info_of_class
            ~detail:"completion contract violated"
            Completion_contract_violation
        in
        { base with
          runtime = { base.runtime with last_blocker = Some blocker };
        }
      in
      Eio.Fiber.fork ~sw (fun () ->
        let cb =
          GP.to_oas_approval_callback
            ~config ~governance_level:"production" ~keeper_name ~meta ()
        in
        let decision =
          cb
            ~tool_name:"masc_create_task"
            ~input:(`Assoc [ ("title", `String "test") ])
        in
        result := Some decision);
      yield_until (fun () -> AQ.pending_count () = initial_pending + 1);
      Alcotest.(check int)
        "typed last_blocker prevents always_approve bypass"
        (initial_pending + 1)
        (AQ.pending_count ());
      let id =
        match pending_id_for_keeper ~keeper_name with
        | Some id -> id
        | None -> Alcotest.fail "expected pending approval for runtime blocker"
      in
      (match AQ.resolve ~id ~decision:(Agent_sdk.Hooks.Reject "blocked") with
       | Ok () -> ()
       | Error err -> Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
      yield_until (fun () -> Option.is_some !result);
      match !result with
      | Some (Agent_sdk.Hooks.Reject "blocked") -> ()
      | Some Agent_sdk.Hooks.Approve ->
        Alcotest.fail "typed last_blocker must not auto-approve"
      | Some (Agent_sdk.Hooks.Reject reason) ->
        Alcotest.fail ("unexpected reject reason: " ^ reason)
      | Some (Agent_sdk.Hooks.Edit _) -> Alcotest.fail "unexpected edit"
      | None -> Alcotest.fail "runtime blocker callback did not suspend")

let test_callback_transient_last_blocker_allows_always_approve () =
  with_test_config @@ fun config ->
  let keeper_name = "transient-blocked-keeper" in
  let meta =
    let base =
      meta_from_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String ("keeper-" ^ keeper_name ^ "-agent"));
            ("trace_id", `String "transient-blocked-trace");
            ("sandbox_profile", `String "docker");
            ("network_mode", `String "inherit");
            ("always_approve", `Bool true);
          ])
    in
    let blocker =
      let open Masc.Keeper_meta_contract in
      blocker_info_of_class ~detail:"previous turn timed out" Turn_timeout
    in
    { base with
      runtime = { base.runtime with last_blocker = Some blocker };
    }
  in
  let cb =
    GP.to_oas_approval_callback
      ~config ~governance_level:"production" ~keeper_name ~meta ()
  in
  let decision =
    cb ~tool_name:"masc_create_task" ~input:(`Assoc [ ("title", `String "test") ])
  in
  match decision with
  | Agent_sdk.Hooks.Approve -> ()
  | Agent_sdk.Hooks.Reject r ->
    Alcotest.fail
      ("transient last_blocker must not block always_approve, got Reject: " ^ r)
  | Agent_sdk.Hooks.Edit _ -> Alcotest.fail "unexpected edit"

let test_runtime_trust_classifies_always_approve_flag () =
  with_test_config @@ fun config ->
  AQ.For_testing.reset_audit_store ();
  Fun.protect
    ~finally:AQ.For_testing.reset_audit_store
    (fun () ->
      let keeper_name = "always-flag-keeper" in
      let meta =
        meta_from_json
          (`Assoc [
            ("name", `String keeper_name);
            ("trace_id", `String "trace-always-flag");
            ("sandbox_profile", `String "docker");
            ("network_mode", `String "inherit");
            ("always_approve", `Bool true);
          ])
      in
      AQ.audit_approval_event ~base_path:config.base_path
        ~event_type:"auto_approved_always" ~id:"auto-always-flag-test"
        ~keeper_name ~tool_name:"masc_create_task" ~risk_level:AQ.Medium
        ~auto_approved:true ();
      let snapshot =
        Masc.Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
      in
      let open Yojson.Safe.Util in
      let approval = snapshot |> member "approval" in
      Alcotest.(check string) "runtime trust always flag state" "always_flag"
        (approval |> member "state" |> to_string);
      Alcotest.(check string) "runtime trust latest event kind"
        "auto_approved_always"
        (approval |> member "latest_event_kind" |> to_string))

let test_callback_always_approve_respects_forbidden () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let initial_pending = AQ.pending_count () in
  let result = ref None in
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let config = (Mcp_server.workspace_config state) in
      let meta =
        meta_from_json
          (`Assoc [
            ("name", `String "test-keeper");
            ("trace_id", `String "test-trace");
            ("sandbox_profile", `String "docker");
            ("network_mode", `String "inherit");
            ("always_approve", `Bool true);
          ])
      in
      Eio.Fiber.fork ~sw (fun () ->
        let cb =
          GP.to_oas_approval_callback
            ~config ~governance_level:"production" ~keeper_name:"test-keeper" ~meta ()
        in
        let decision =
          cb ~tool_name:"tool_edit_file"
            ~input:(`Assoc [("path", `String "/dangerous")])
        in
        result := Some decision
      );
      yield_until (fun () -> AQ.pending_count () = initial_pending + 1);
      Alcotest.(check int) "destructive tool still requires approval"
        (initial_pending + 1) (AQ.pending_count ());
      let pending_json = AQ.list_pending_json () in
      let id =
        match pending_json with
        | `List (`Assoc kvs :: _) ->
          (match List.assoc_opt "id" kvs with
           | Some (`String id) -> id
           | _ -> Alcotest.fail "missing approval id")
        | _ -> Alcotest.fail "expected pending approval entry"
      in
      (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
       | Ok () -> ()
       | Error err -> Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
      yield_until (fun () -> Option.is_some !result);
      match !result with
      | Some Agent_sdk.Hooks.Approve -> ()
      | Some _ -> Alcotest.fail "expected Approve after operator resolution"
      | None -> Alcotest.fail "destructive tool callback did not suspend for approval")

let test_callback_hitl_disabled_forbidden_requires_approval () =
  with_env "MASC_DISABLE_HITL" "true" @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let keeper_name = "hitl-disabled-forbidden-keeper" in
  let initial_pending = AQ.pending_count () in
  let result = ref None in
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let config = Mcp_server.workspace_config state in
      Eio.Fiber.fork ~sw (fun () ->
        let cb =
          GP.to_oas_approval_callback
            ~config ~governance_level:"production" ~keeper_name ()
        in
        let decision =
          cb
            ~tool_name:"tool_edit_file"
            ~input:(`Assoc [ ("path", `String "/dangerous") ])
        in
        result := Some decision);
      yield_until (fun () -> AQ.pending_count () = initial_pending + 1);
      Alcotest.(check int)
        "forbidden tool still requires approval when HITL threshold is disabled"
        (initial_pending + 1)
        (AQ.pending_count ());
      let id =
        match pending_id_for_keeper ~keeper_name with
        | Some id -> id
        | None -> Alcotest.fail "expected pending approval for HITL-disabled forbidden tool"
      in
      (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
       | Ok () -> ()
       | Error err ->
         Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
      yield_until (fun () -> Option.is_some !result);
      match !result with
      | Some Agent_sdk.Hooks.Approve -> ()
      | Some Agent_sdk.Hooks.Reject reason ->
        Alcotest.fail ("expected Approve after operator resolution, got reject: " ^ reason)
      | Some Agent_sdk.Hooks.Edit _ ->
        Alcotest.fail "expected Approve after operator resolution, got edit"
      | None ->
        Alcotest.fail "HITL-disabled forbidden callback did not suspend for approval")

let test_callback_hitl_disabled_soft_forbidden_auto_approved () =
  with_env "MASC_DISABLE_HITL" "true" @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let keeper_name = "hitl-disabled-soft-forbidden-keeper" in
  let input = `Assoc [ ("op", `String "git") ] in
  Alcotest.(check string)
    "soft-only fixture stays below hard-forbidden risk"
    "low"
    (GP.assess_risk ~tool_name:"masc_status" ~input |> GP.risk_level_to_string);
  let initial_pending = AQ.pending_count () in
  let result = ref None in
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let config = Mcp_server.workspace_config state in
      Eio.Fiber.fork ~sw (fun () ->
        let cb =
          GP.to_oas_approval_callback
            ~config ~governance_level:"production" ~keeper_name ()
        in
        let decision = cb ~tool_name:"masc_status" ~input in
        result := Some decision);
      yield_until (fun () ->
        Option.is_some !result
        || Option.is_some (pending_id_for_keeper ~keeper_name));
      let queued =
        match pending_id_for_keeper ~keeper_name with
        | Some id ->
          (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
           | Ok () -> ()
           | Error err ->
             Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
          true
        | None -> false
      in
      yield_until (fun () -> Option.is_some !result);
      Alcotest.(check bool)
        "soft destructive op does not queue when HITL threshold is disabled"
        false
        queued;
      Alcotest.(check int)
        "pending count unchanged"
        initial_pending
        (AQ.pending_count ());
      match !result with
      | Some Agent_sdk.Hooks.Approve -> ()
      | Some Agent_sdk.Hooks.Reject reason ->
        Alcotest.fail ("expected Approve for HITL-disabled soft match, got reject: " ^ reason)
      | Some Agent_sdk.Hooks.Edit _ ->
        Alcotest.fail "expected Approve for HITL-disabled soft match, got edit"
      | None ->
        Alcotest.fail "HITL-disabled soft-forbidden callback did not return")

let test_read_recent_audit_filters_after_wide_scan () =
  with_temp_masc_base @@ fun base_path ->
  let keeper_name = "audit-target-keeper" in
  AQ.audit_approval_event ~base_path
    ~event_type:AQ.approval_audit_resolved_event ~id:"target-audit" ~keeper_name
    ~tool_name:"tool_search_files" ~risk_level:AQ.Medium
    ~selected_model:"openai:gpt-5.4"
    ~decision:(AQ.Approval_resolved Agent_sdk.Hooks.Approve) ();
  for i = 1 to 32 do
    AQ.audit_approval_event ~base_path ~event_type:AQ.approval_audit_resolved_event
      ~id:(Printf.sprintf "other-audit-%02d" i)
      ~keeper_name:(Printf.sprintf "busy-keeper-%02d" i)
      ~tool_name:"tool_search_files" ~risk_level:AQ.Medium
      ~decision:(AQ.Approval_resolved Agent_sdk.Hooks.Approve) ()
  done;
  match AQ.read_recent_audit ~base_path ~keeper_name ~n:1 () with
  | [ json ] ->
      Alcotest.(check string) "target approval survives unrelated tail"
        "target-audit"
        Yojson.Safe.Util.(json |> member "id" |> to_string);
      Alcotest.(check bool) "audit selected model redacted" true
        Yojson.Safe.Util.(json |> member "selected_model" = `Null)
  | items ->
      Alcotest.fail
        (Printf.sprintf "expected one target audit, got %d" (List.length items))

let test_list_recent_resolved_json_projects_resolved_history () =
  with_temp_masc_base @@ fun base_path ->
  let keeper_name = "resolved-history-target" in
  AQ.audit_approval_event ~base_path
    ~event_type:AQ.approval_audit_resolved_event ~id:"older-resolved"
    ~keeper_name ~tool_name:"tool_search_files" ~risk_level:AQ.Medium
    ~decision:(AQ.Approval_resolved (Agent_sdk.Hooks.Reject "operator denied")) ();
  for i = 1 to 64 do
    AQ.audit_approval_event ~base_path
      ~event_type:AQ.approval_audit_pending_event
      ~id:(Printf.sprintf "pending-noise-%02d" i)
      ~keeper_name:(Printf.sprintf "busy-keeper-%02d" i)
      ~tool_name:"tool_search_files" ~risk_level:AQ.Low ()
  done;
  AQ.audit_approval_event ~base_path
    ~event_type:AQ.approval_audit_resolved_event ~id:"newer-resolved"
    ~keeper_name ~tool_name:"tool_search_files" ~risk_level:AQ.Medium
    ~decision:(AQ.Approval_resolved Agent_sdk.Hooks.Approve) ();
  match AQ.list_recent_resolved_json ~base_path ~n:2 () with
  | [ newest; older ] ->
    let open Yojson.Safe.Util in
    Alcotest.(check string) "newest first" "newer-resolved"
      (newest |> member "id" |> to_string);
    Alcotest.(check string) "older second" "older-resolved"
      (older |> member "id" |> to_string);
    Alcotest.(check string) "keeper name" keeper_name
      (older |> member "keeper_name" |> to_string);
    Alcotest.(check string) "tool name" "tool_search_files"
      (older |> member "tool_name" |> to_string);
    Alcotest.(check string) "risk level" "medium"
      (older |> member "risk_level" |> to_string);
    Alcotest.(check string) "decision" "reject:operator denied"
      (older |> member "decision" |> to_string);
    Alcotest.(check string) "decision kind" "reject"
      (older |> member "decision_kind" |> to_string);
    Alcotest.(check string) "decision reason" "operator denied"
      (older |> member "decision_reason" |> to_string);
    Alcotest.(check bool) "resolved_at float present" true
      (older |> member "resolved_at" |> to_float > 0.0);
    Alcotest.(check bool) "resolved_at_iso present" true
      (contains_substring (older |> member "resolved_at_iso" |> to_string) "T");
    Alcotest.(check bool) "pending timestamp omitted" false
      (has_assoc_key "requested_at" older)
  | items ->
    Alcotest.fail
      (Printf.sprintf "expected two resolved audits, got %d" (List.length items))

let test_runtime_trust_approval_read_model_filters_after_wide_scan () =
  with_test_config @@ fun config ->
  AQ.For_testing.reset_audit_store ();
  Fun.protect
    ~finally:AQ.For_testing.reset_audit_store
    (fun () ->
      let keeper_name = "runtime-trust-audit-target" in
      let meta =
        meta_from_json
          (`Assoc [
            ("name", `String keeper_name);
            ("trace_id", `String "trace-runtime-trust-audit-target");
            ("sandbox_profile", `String "docker");
            ("network_mode", `String "inherit");
          ])
      in
      AQ.audit_approval_event ~base_path:config.base_path
        ~event_type:AQ.approval_audit_resolved_event
        ~id:"runtime-trust-target-audit"
        ~keeper_name ~tool_name:"tool_search_files" ~risk_level:AQ.Medium
        ~decision:(AQ.Approval_resolved Agent_sdk.Hooks.Approve) ();
      for i = 1 to 64 do
        AQ.audit_approval_event ~base_path:config.base_path
          ~event_type:AQ.approval_audit_resolved_event
          ~id:(Printf.sprintf "runtime-trust-other-audit-%02d" i)
          ~keeper_name:(Printf.sprintf "busy-runtime-keeper-%02d" i)
          ~tool_name:"tool_search_files" ~risk_level:AQ.Medium
          ~decision:(AQ.Approval_resolved Agent_sdk.Hooks.Approve) ()
      done;
      let snapshot =
        Masc.Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
      in
      let open Yojson.Safe.Util in
      let approval = snapshot |> member "approval" in
      Alcotest.(check string) "runtime trust approval state" "resolved"
        (approval |> member "state" |> to_string);
      Alcotest.(check string) "runtime trust latest event kind" "resolved"
        (approval |> member "latest_event_kind" |> to_string);
      let approval_events =
        snapshot |> member "causal_timeline" |> to_list
        |> List.filter (fun event ->
          String.equal "approval_resolved"
            (event |> member "kind" |> to_string))
      in
      Alcotest.(check int) "one filtered approval event" 1
        (List.length approval_events);
      match approval_events with
      | [ event ] ->
        Alcotest.(check bool) "approval event title mentions tool" true
          (contains_substring (event |> member "title" |> to_string) "tool_search_files");
        Alcotest.(check bool) "approval event summary mentions target keeper" true
          (contains_substring (event |> member "summary" |> to_string) keeper_name)
      | _ -> Alcotest.fail "expected exactly one target approval event")

(* ── Test runner ──────────────────────────────────────────── *)

let () =
  Unix.putenv "MASC_DISABLE_HITL" "false";
  Alcotest.run "HITL Approval" [
    ("risk_classification", [
      Alcotest.test_case "critical tools" `Quick test_risk_classification_critical;
      Alcotest.test_case "high-risk tools" `Quick test_risk_classification_high;
      Alcotest.test_case "low-risk tools" `Quick test_risk_classification_low;
    ]);
    ("threshold_decisions", [
      Alcotest.test_case "development allows all" `Quick test_development_allows_all;
      Alcotest.test_case "paranoid blocks medium+" `Quick test_paranoid_blocks_medium;
      Alcotest.test_case "production blocks critical" `Quick test_production_blocks_critical;
      Alcotest.test_case "enterprise blocks high+" `Quick test_enterprise_blocks_high;
    ]);
    ("approval_queue", [
      Alcotest.test_case "submit and approve" `Quick test_approval_queue_submit_and_resolve;
      Alcotest.test_case "submit and reject" `Quick test_approval_queue_reject;
      Alcotest.test_case "expire stale" `Quick test_approval_queue_expire_stale;
      Alcotest.test_case "expire skips Critical" `Quick test_approval_queue_expire_skips_critical;
      Alcotest.test_case "submit timeout skips Critical" `Quick
        test_submit_and_await_clock_timeout_skips_critical;
      Alcotest.test_case "Critical escalation waits for manual decision" `Quick
        test_submit_and_await_critical_escalates_then_waits;
      Alcotest.test_case "submit timeout returns manual winner" `Quick
        test_submit_and_await_clock_returns_manual_decision;
      Alcotest.test_case "resolve nonexistent" `Quick test_approval_resolve_nonexistent;
      Alcotest.test_case "cancel cleans up" `Quick test_approval_queue_cancel_cleans_up;
      Alcotest.test_case "cancel records terminal audit" `Quick
        test_approval_queue_cancel_records_terminal_audit;
      Alcotest.test_case "failure observation labels site" `Quick
        test_approval_queue_failure_metric_labels_site;
      Alcotest.test_case "first cmd token uses shared words" `Quick
        test_first_cmd_token_uses_shared_words;
      Alcotest.test_case "background pending callback" `Quick
        test_background_pending_callback_and_keeper_lookup;
      Alcotest.test_case "background pending reuses existing entry" `Quick
        test_background_pending_reuses_existing_entry;
      Alcotest.test_case "background pending distinct inputs do not reuse entry" `Quick
        test_background_pending_distinct_inputs_do_not_reuse_entry;
      Alcotest.test_case "get pending detail includes full input" `Quick
        test_approval_queue_get_pending_detail;
      Alcotest.test_case "runtime_contract redacts sandbox backend" `Quick
        test_approval_queue_keeps_sandbox_backend_out_of_runtime_contract;
      Alcotest.test_case "resolve_with_policy remembers medium allow" `Quick
        test_resolve_with_policy_remembers_medium_allow;
      Alcotest.test_case "resolve_with_policy skips high allow memory" `Quick
        test_resolve_with_policy_does_not_remember_high_allow;
      Alcotest.test_case "runtime_contract policy uses workspace base_path" `Quick
        test_runtime_contract_policy_uses_workspace_base_path;
      Alcotest.test_case "dashboard approve-always rules use workspace base_path" `Quick
        test_dashboard_resolve_and_delete_rules_use_workspace_base_path;
      Alcotest.test_case "submit_pending audit uses workspace base_path" `Quick
        test_submit_pending_audit_uses_workspace_base_path;
      Alcotest.test_case "read_recent_audit scans before keeper filter" `Quick
        test_read_recent_audit_filters_after_wide_scan;
      Alcotest.test_case
        "list_recent_resolved_json projects resolved history" `Quick
        test_list_recent_resolved_json_projects_resolved_history;
      Alcotest.test_case
        "runtime trust approval read model scans before keeper filter" `Quick
        test_runtime_trust_approval_read_model_filters_after_wide_scan;
    ]);
    ("callback_integration", [
      Alcotest.test_case "low risk auto-approved" `Quick test_callback_approves_low_risk;
      Alcotest.test_case "production keeper write requires approval" `Quick
        test_callback_production_tool_edit_file_requires_approval;
      Alcotest.test_case "production claimed worktree write auto-approved" `Quick
        test_callback_production_claimed_worktree_write_auto_approved;
      Alcotest.test_case "production worktree preparation requires approval" `Quick
        test_callback_production_worktree_prepare_requires_approval;
      Alcotest.test_case "paranoid medium risk uses remembered policy" `Quick
        test_callback_paranoid_medium_risk_uses_remembered_policy;
      Alcotest.test_case "always_approve bypasses threshold" `Quick
        test_callback_always_approve_bypasses_threshold;
      Alcotest.test_case "typed last_blocker overrides always_approve" `Quick
        test_callback_typed_last_blocker_overrides_always_approve;
      Alcotest.test_case "transient last_blocker allows always_approve" `Quick
        test_callback_transient_last_blocker_allows_always_approve;
      Alcotest.test_case "runtime trust classifies always_approve flag" `Quick
        test_runtime_trust_classifies_always_approve_flag;
      Alcotest.test_case "always_approve respects forbidden" `Quick
        test_callback_always_approve_respects_forbidden;
      Alcotest.test_case "HITL disabled still gates forbidden tools" `Quick
        test_callback_hitl_disabled_forbidden_requires_approval;
      Alcotest.test_case "HITL disabled allows soft forbidden tools" `Quick
        test_callback_hitl_disabled_soft_forbidden_auto_approved;
    ]);
  ]
