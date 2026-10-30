module AQ = Masc.Keeper_approval_queue
module Gate = Masc.Keeper_gate
module Mode = Masc.Keeper_gate_mode
module Rule_types = Keeper_approval_queue_rules_types

let get show = function Ok value -> value | Error error -> Alcotest.fail (show error)

let with_workspace f =
  let base_path = Filename.temp_file "keeper-gate-alias-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
  in
  AQ.For_testing.reset_runtime_state ();
  Keeper_approval.Audit.For_testing.reset_store ();
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      Keeper_approval.Audit.For_testing.reset_store ();
      remove base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      let keeper_name = "gate-alias-owner" in
      let meta =
        Masc_test_deps.meta_of_json_fixture
          (`Assoc [ "name", `String keeper_name; "trace_id", `String "alias-proof" ])
        |> get Fun.id
      in
      Masc.Keeper_meta_store.replace_snapshot config meta |> get Fun.id;
      ignore (AQ.install_persistence ~base_path |> get Masc.Keeper_approval_queue_result.install_error_to_string);
      f config keeper_name (Filename.concat base_path ".masc"))
;;

let request ~base_path ~keeper_name : Gate.request =
  { keeper_name; base_path; operation = "filesystem_write"
  ; input = `Assoc [ "path", `String "reviewed.txt"; "content", `String "approved" ]
  ; call_summary = None; causal_context = None; task_id = None
  ; continuation_channel = None; sandbox_profile = None
  }
;;

let manual_approval request decide =
  match decide request with
  | Gate.Deferred { approval_id; reason = Gate.Human_requested; _ } -> approval_id
  | Gate.Deferred _ -> Alcotest.fail "canonical manual mode did not govern the alias request"
  | Gate.Allow _ -> Alcotest.fail "manual approval was bypassed"
  | Gate.Unavailable reason -> Alcotest.fail (Gate.unavailable_reason_to_string reason)
;;

let test_manual_alias_and_audit ?(alias_input = true) external_lane () =
  with_workspace (fun config keeper_name alias ->
    let base_path = config.Masc.Workspace.base_path in
    ignore ((if external_lane then Mode.set_external else Mode.set) config ~actor:"operator" Mode.Manual |> get Fun.id);
    let decide request =
      if external_lane then Gate.decide_external_service ~keeper_always_allow:false request
      else Gate.decide ~keeper_always_allow:false request
    in
    let input_base = if alias_input then alias else base_path in
    let id = manual_approval (request ~base_path:input_base ~keeper_name) decide in
    let pending = AQ.list_pending_entries_for_workspace ~base_path
      |> get Masc.Keeper_approval_queue_result.storage_error_to_string in
    Alcotest.(check (list string)) "alias request belongs to the installed owner" [ id ]
      (List.map (fun (entry : Rule_types.pending_approval) -> entry.id) pending);
    List.iter (fun (entry : Rule_types.pending_approval) ->
      Alcotest.(check string) "durable audit owner is canonical" base_path entry.audit_base_path) pending;
    let rows = Keeper_approval.Audit.read_recent ~base_path ()
      |> get Keeper_approval.Audit.read_error_to_string in
    Alcotest.(check bool) "pending audit is visible from the canonical workspace" true
      (List.exists (fun row -> Yojson.Safe.Util.member "id" row = `String id) rows);
    Alcotest.(check bool) "no nested runtime directory was created" false
      (Sys.file_exists (Filename.concat alias ".masc")))
;;

let test_alias_consumes_one_exact_grant () =
  with_workspace (fun config keeper_name alias ->
    let base_path = config.Masc.Workspace.base_path in
    ignore (Mode.set config ~actor:"operator" Mode.Manual |> get Fun.id);
    let req = request ~base_path ~keeper_name in
    let id = manual_approval req (Gate.decide ~keeper_always_allow:false) in
    ignore (AQ.resolve_with_policy ~base_path ~id ~decision:Rule_types.Decision.Approve
      ~source:Rule_types.Human_operator () |> get AQ.resolve_error_to_string);
    let queue = Masc.Keeper_registry_event_queue.snapshot_result ~base_path keeper_name |> get Fun.id in
    let resolution = Keeper_event_queue.to_list queue |> List.find_map (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Keeper_event_queue.Hitl_resolved value when String.equal value.approval_id id -> Some value
      | _ -> None) |> Option.get in
    let grant = Gate.cycle_grant_of_resolution resolution |> Option.get in
    (match Gate.decide ~cycle_grant:grant ~keeper_always_allow:false { req with base_path = alias } with
     | Gate.Allow { source = Gate.One_shot_resolution consumed; _ } ->
       Alcotest.(check string) "alias consumes the original approval" id consumed
     | Gate.Allow _ | Gate.Deferred _ | Gate.Unavailable _ -> Alcotest.fail "alias lost its canonical one-shot grant");
    (match AQ.approved_resolution_state ~base_path ~id |> get Masc.Keeper_approval_queue_result.grant_error_to_string with
     | Masc.Keeper_approval_queue_result.Resolution_consumed -> ()
     | Masc.Keeper_approval_queue_result.Resolution_unconsumed -> Alcotest.fail "grant consumption was not committed");
    let rows = Keeper_approval.Audit.read_recent ~base_path () |> get Keeper_approval.Audit.read_error_to_string in
    let event_count event = List.filter (fun row ->
      Yojson.Safe.Util.member "event" row = `String event) rows |> List.length in
    Alcotest.(check int) "one canonical consumption audit" 1 (event_count "grant_consumed");
    Alcotest.(check int) "one canonical authorization audit" 1 (event_count "gate_allowed"))
;;

let test_alias_reads_the_canonical_exact_rule () =
  with_workspace (fun config keeper_name alias ->
    let base_path = config.Masc.Workspace.base_path in
    ignore (Mode.set config ~actor:"operator" Mode.Manual |> get Fun.id);
    let req = request ~base_path ~keeper_name in
    let id = manual_approval req (Gate.decide ~keeper_always_allow:false) in
    let resolution = AQ.resolve_with_policy ~base_path ~id ~decision:Rule_types.Decision.Approve
      ~source:Rule_types.Human_operator ~remember_rule:true () |> get AQ.resolve_error_to_string in
    let rule = resolution.remembered_rule |> Option.get in
    AQ.For_testing.reset_runtime_state ();
    ignore (AQ.install_persistence ~base_path |> get Masc.Keeper_approval_queue_result.install_error_to_string);
    match Gate.decide ~keeper_always_allow:false { req with base_path = alias } with
    | Gate.Allow { source = Gate.Exact_always_rule actual; _ } ->
      Alcotest.(check string) "alias uses the original persisted exact rule" rule.id actual
    | Gate.Allow _ | Gate.Deferred _ | Gate.Unavailable _ ->
      Alcotest.fail "alias did not read its canonical exact-rule store")
;;

let test_alias_restart_recovery_selects_canonical_pending () =
  with_workspace (fun config keeper_name alias ->
    let base_path = config.Masc.Workspace.base_path in
    ignore (Mode.set config ~actor:"operator" Mode.Manual |> get Fun.id);
    let id = manual_approval (request ~base_path ~keeper_name) (Gate.decide ~keeper_always_allow:false) in
    ignore (Mode.set config ~actor:"operator" Mode.Auto_judge |> get Fun.id);
    AQ.For_testing.reset_runtime_state ();
    ignore (AQ.install_persistence ~base_path |> get Masc.Keeper_approval_queue_result.install_error_to_string);
    let report = Gate.resume_persisted_auto_judges ~base_path:alias in
    Alcotest.(check bool) "canonical queue was readable" true (Option.is_none report.queue_error);
    Alcotest.(check int) "alias recovery selected the persisted owner" 1 report.requested;
    let observed = report.started_ids @ report.finalized_ids
      @ List.map (fun (failure : Gate.auto_judge_resume_failure) -> failure.approval_id) report.failures in
    Alcotest.(check (list string)) "recovery attempted exactly the original approval" [ id ] observed)
;;

let test_alias_retry_reads_the_canonical_owner () =
  with_workspace (fun config keeper_name alias ->
    let base_path = config.Masc.Workspace.base_path in
    ignore (Mode.set config ~actor:"operator" Mode.Manual |> get Fun.id);
    let id = manual_approval (request ~base_path ~keeper_name) (Gate.decide ~keeper_always_allow:false) in
    let entry = AQ.get_pending_entry_for_workspace ~base_path ~id
      |> get Masc.Keeper_approval_queue_result.storage_error_to_string |> Option.get in
    match Gate.retry_blocked_auto_judge_typed ~base_path:alias ~requested_by:"operator"
      ~expected_input_hash:entry.input_hash ~expected_sequence:entry.sequence
      ~expected_exact_attempt:entry.exact_attempt ~expected_disposition:entry.summary_attempt_disposition id with
    | Error (Gate.Retry_not_auto_judge owner) ->
      Alcotest.(check string) "retry inspected the actual manual owner" keeper_name owner
    | Error _ | Ok () -> Alcotest.fail "alias retry did not inspect the canonical pending row and mode")
;;

let () = Alcotest.run "Gate workspace aliases"
  [ "actual boundary",
    [ Alcotest.test_case "manual request and audit" `Quick (test_manual_alias_and_audit false)
    ; Alcotest.test_case "external request and audit" `Quick (test_manual_alias_and_audit true)
    ; Alcotest.test_case "canonical owner control" `Quick (test_manual_alias_and_audit ~alias_input:false false)
    ; Alcotest.test_case "exact grant consumption" `Quick test_alias_consumes_one_exact_grant
    ; Alcotest.test_case "persisted exact rule" `Quick test_alias_reads_the_canonical_exact_rule
    ; Alcotest.test_case "persisted owner restart recovery" `Quick test_alias_restart_recovery_selects_canonical_pending
    ; Alcotest.test_case "operator retry owner" `Quick test_alias_retry_reads_the_canonical_owner
    ] ]
