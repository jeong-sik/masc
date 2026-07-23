open Alcotest

module AQ = Masc.Keeper_approval_queue
module Gate = Masc.Keeper_gate
module Gate_mode = Masc.Keeper_gate_mode

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_approval_queue_rules_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec remove path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  try remove dir with
  | Sys_error _ -> ()
;;

let rec ensure_dir path =
  if Sys.file_exists path
  then ()
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let write_rules ~base_path json =
  let path = AQ.For_testing.always_allowed_store_path ~base_path in
  ensure_dir (Filename.dirname path);
  Out_channel.with_open_text path (fun channel ->
    output_string channel (Yojson.Safe.pretty_to_string json))
;;

let upsert_exn ~base_path ~input =
  match
    AQ.upsert_rule
      ~base_path
      ~keeper_name:"keeper"
      ~tool_name:"external-effect"
      ~input
      ()
  with
  | Ok result -> result
  | Error error -> fail (AQ.rule_store_error_to_string error)
;;

let find ~base_path ~input =
  match
    AQ.find_matching_rule
      ~base_path
      ~keeper_name:"keeper"
      ~tool_name:"external-effect"
      ~input
      ()
  with
  | Ok lookup -> lookup
  | Error error -> fail (AQ.rule_store_error_to_string error)
;;

let find_active_opt ~base_path ~input =
  match find ~base_path ~input with
  | AQ.Rule_match_active matched -> Some matched
  | AQ.Rule_match_expired _ | AQ.Rule_match_absent -> None
;;

let test_rule_matches_only_complete_exact_request () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input =
         `Assoc
           [ "target", `String "/workspace/readme.md"
           ; "payload", `Assoc [ "body", `String "hello"; "nonce", `Int 7 ]
           ]
       in
       let _rule, created = upsert_exn ~base_path ~input in
       check bool "created" true created;
       let reordered =
         `Assoc
           [ "payload", `Assoc [ "nonce", `Int 7; "body", `String "hello" ]
           ; "target", `String "/workspace/readme.md"
           ]
       in
       check bool "object field order is canonical" true
         (Option.is_some (find_active_opt ~base_path ~input:reordered));
       let changed_nonce =
         `Assoc
           [ "target", `String "/workspace/readme.md"
           ; "payload", `Assoc [ "body", `String "hello"; "nonce", `Int 8 ]
           ]
       in
       check bool "no request field is discarded" true
         (Option.is_none (find_active_opt ~base_path ~input:changed_nonce));
       check bool "different operation identity cannot match" true
         (match
            AQ.find_matching_rule
              ~base_path
              ~keeper_name:"keeper"
              ~tool_name:"another-effect"
              ~input
              ()
          with
          | Ok AQ.Rule_match_absent -> true
          | Ok (AQ.Rule_match_active _ | AQ.Rule_match_expired _) -> false
          | Error error -> fail (AQ.rule_store_error_to_string error)))
;;

let test_equivalent_upsert_is_idempotent () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "request", `String "exact" ] in
       let first, first_created = upsert_exn ~base_path ~input in
       let second, second_created = upsert_exn ~base_path ~input in
       check bool "first created" true first_created;
       check bool "second reused" false second_created;
       check string "same rule id" first.id second.id)
;;

let test_gate_allows_only_the_exact_persisted_rule () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input =
         `Assoc
           [ "target", `String "document"
           ; "payload", `Assoc [ "body", `String "exact" ]
           ]
       in
       let rule, _ = upsert_exn ~base_path ~input in
       let request : Gate.request =
         { keeper_name = "keeper"
         ; operation = "external-effect"
         ; input
         ; base_path
         ; causal_context = None
         ; task_id = None
         ; goal_ids = []
         ; continuation_channel = None
         }
       in
       match Gate.decide ~keeper_always_allow:false request with
       | Gate.Allow { source = Gate.Exact_always_rule rule_id } ->
         check string "exact rule id" rule.id rule_id
       | Gate.Allow _ -> fail "Gate used a broader Always Allowed source"
       | Gate.Deferred _ -> fail "exact Always Allowed rule unexpectedly deferred"
       | Gate.Unavailable reason ->
         fail (Gate.unavailable_reason_to_string reason))
;;

let upsert_with_expiry_exn ~base_path ~input ~expires_at =
  match
    AQ.upsert_rule
      ~base_path
      ~keeper_name:"keeper"
      ~tool_name:"external-effect"
      ~input
      ~expires_at
      ()
  with
  | Ok result -> result
  | Error error -> fail (AQ.rule_store_error_to_string error)
;;

let find_at ~base_path ~input ~now =
  match
    AQ.find_matching_rule
      ~base_path
      ~keeper_name:"keeper"
      ~tool_name:"external-effect"
      ~input
      ~now
      ()
  with
  | Ok lookup -> lookup
  | Error error -> fail (AQ.rule_store_error_to_string error)
;;

let test_unexpired_rule_matches_with_injected_now () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "request", `String "exact" ] in
       let rule, created =
         upsert_with_expiry_exn ~base_path ~input ~expires_at:2000.0
       in
       check bool "created" true created;
       check (option (float 0.0)) "expiry persisted on rule" (Some 2000.0)
         rule.expires_at;
       match find_at ~base_path ~input ~now:1999.0 with
       | AQ.Rule_match_active matched ->
         check string "unexpired rule matches" rule.id matched.rule_id
       | AQ.Rule_match_expired _ -> fail "unexpired rule reported as expired"
       | AQ.Rule_match_absent -> fail "unexpired rule did not match")
;;

let test_expired_rule_is_reported_and_retained () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "request", `String "exact" ] in
       let rule, _ = upsert_with_expiry_exn ~base_path ~input ~expires_at:2000.0 in
       (match find_at ~base_path ~input ~now:2000.0 with
        | AQ.Rule_match_expired matched ->
          check string "expiry boundary is expired" rule.id matched.rule_id
        | AQ.Rule_match_active _ -> fail "expired rule still matched"
        | AQ.Rule_match_absent -> fail "expired rule must be reported, not absent");
       (match find_at ~base_path ~input ~now:2001.0 with
        | AQ.Rule_match_expired matched ->
          check string "after expiry is expired" rule.id matched.rule_id
        | AQ.Rule_match_active _ -> fail "expired rule still matched"
        | AQ.Rule_match_absent -> fail "expired rule must be reported, not absent");
       let stored =
         match AQ.list_rules ~base_path () with
         | Ok rules -> rules
         | Error error -> fail (AQ.rule_store_error_to_string error)
       in
       check bool "expired rule is retained for operator cleanup" true
         (List.exists (fun (stored : AQ.approval_rule) ->
            String.equal stored.id rule.id && stored.expires_at = Some 2000.0)
            stored))
;;

let test_rule_without_expiry_matches_at_any_now () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "request", `String "exact" ] in
       let rule, _ = upsert_exn ~base_path ~input in
       check (option (float 0.0)) "no expiry by default" None rule.expires_at;
       match find_at ~base_path ~input ~now:1e12 with
       | AQ.Rule_match_active matched ->
         check string "rule without expiry stays active" rule.id matched.rule_id
       | AQ.Rule_match_expired _ -> fail "rule without expiry reported as expired"
       | AQ.Rule_match_absent -> fail "rule without expiry did not match")
;;

let test_unknown_persisted_shape_is_reported_and_rejected () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "request", `String "exact" ] in
       let rule, _ = upsert_exn ~base_path ~input in
       let json = AQ.approval_rule_to_yojson rule in
       let extended =
         match json with
         | `Assoc fields -> `Assoc (("classification", `String "legacy") :: fields)
         | other -> other
       in
       let before =
         Masc.Otel_metric_store.metric_value_or_zero
           Masc.Otel_metric_store.metric_persistence_read_drops
           ~labels:
             [ "surface", "keeper_approval_rules"
             ; "reason", "invalid_payload"
             ]
           ()
       in
       write_rules ~base_path (`List [ json; extended ]);
       (match AQ.list_rules ~base_path () with
        | Ok _ -> fail "unsupported entry must fail the whole rules file"
        | Error _ -> ());
       let after =
         Masc.Otel_metric_store.metric_value_or_zero
           Masc.Otel_metric_store.metric_persistence_read_drops
           ~labels:
             [ "surface", "keeper_approval_rules"
             ; "reason", "invalid_payload"
             ]
           ()
       in
       check bool "rejection is observed" true (after -. before >= 1.0))
;;

let with_rule_id id (rule : AQ.approval_rule) = { rule with id }

let test_duplicate_persisted_rules_reject_whole_store () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let first, _ =
         upsert_exn ~base_path ~input:(`Assoc [ "request", `String "first" ])
       in
       let second, _ =
         upsert_exn ~base_path ~input:(`Assoc [ "request", `String "second" ])
       in
       write_rules
         ~base_path
         (`List
             [ AQ.approval_rule_to_yojson first
             ; AQ.approval_rule_to_yojson (with_rule_id first.id second)
             ]);
       (match AQ.list_rules ~base_path () with
        | Ok _ -> fail "duplicate rule ids must fail the whole rules store"
        | Error error ->
          check bool "duplicate id named" true
            (String.starts_with
               ~prefix:"duplicate approval rule id "
               error.reason));
       write_rules
         ~base_path
         (`List
             [ AQ.approval_rule_to_yojson first
             ; AQ.approval_rule_to_yojson (with_rule_id "different-id" first)
             ]);
       match AQ.list_rules ~base_path () with
       | Ok _ -> fail "duplicate exact identities must fail the whole rules store"
       | Error error ->
         check bool "duplicate identity named" true
           (String.starts_with
              ~prefix:"duplicate exact Always Allowed identity"
              error.reason))
;;

let gate_request ~base_path : Gate.request =
  { keeper_name = "keeper"
  ; operation = "external-effect"
  ; input = `Assoc [ "target", `String "exact" ]
  ; base_path
  ; causal_context = None
  ; task_id = None
  ; goal_ids = []
  ; continuation_channel = None
  }
;;

let with_gate_fixture f =
  let base_path = temp_dir () in
  AQ.For_testing.reset_runtime_state ();
  AQ.For_testing.reset_audit_store ();
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      AQ.For_testing.reset_audit_store ();
      cleanup_dir base_path)
    (fun () ->
       (match AQ.install_persistence ~base_path with
        | Ok _report -> ()
        | Error error -> fail (AQ.install_error_to_string error));
       f base_path)
;;

let exact_rule_lookup_failure_count () =
  Masc.Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:[ "keeper", "keeper"; "site", "exact_rule_lookup" ]
    ()
;;

let eligibility_summary : AQ.hitl_context_summary =
  { summary_version = 2
  ; generated_at = 1.0
  ; model_run_id = "gate-eligibility-judge"
  ; context_summary = "The exact request is supported by the visible context."
  ; key_questions = []
  ; judgment = AQ.Approve
  ; rationale = "The request is safe to finalize."
  }
;;

type eligibility_exact_identity =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

let approval_entry_exn id =
  match AQ.get_pending_entry ~id with
  | Some entry -> entry
  | None -> fail ("pending approval not found: " ^ id)
;;

let submit_eligibility_entry ~base_path ~keeper_name label =
  match
    AQ.submit_pending
      ~keeper_name
      ~tool_name:"external-effect"
      ~input:(`Assoc [ "request", `String label ])
      ~base_path
      ()
  with
  | Ok id -> approval_entry_exn id
  | Error error -> fail (AQ.storage_error_to_string error)
;;

let summary_update_exn label = function
  | Ok true -> ()
  | Ok false -> fail (label ^ " did not update the pending approval")
  | Error error -> fail (AQ.summary_transition_error_to_string error)
;;

let exact_update_exn label = function
  | Ok { AQ.changed = true; write_outcome = AQ.Fsync_completed } -> ()
  | Ok { changed = false; write_outcome = AQ.Fsync_completed } ->
    fail (label ^ " did not update the exact attempt")
  | Ok { write_outcome = AQ.Visible_sync_unconfirmed detail; _ } ->
    fail (label ^ " returned visible durability uncertainty: " ^ detail)
  | Error error -> fail (AQ.exact_attempt_error_to_string error)
;;

let exact_identity label =
  { slot_id = "exact-slot-" ^ label
  ; call_id = "exact-call-" ^ label
  ; plan_fingerprint = String.make 64 'b'
  ; request_body_sha256 = String.make 64 'c'
  }
;;

let bind_exact_entry (entry : AQ.pending_approval) identity =
  exact_update_exn
    "bind exact attempt"
    (AQ.bind_summary_exact_attempt
       ~id:entry.id
       ~input_hash:entry.input_hash
       ~sequence:entry.sequence
       ~slot_id:identity.slot_id
       ~call_id:identity.call_id
       ~plan_fingerprint:identity.plan_fingerprint
       ~request_body_sha256:identity.request_body_sha256);
  approval_entry_exn entry.id
;;

let test_gate_auto_judge_worker_eligibility_ssot () =
  with_gate_fixture @@ fun base_path ->
  let keeper_name = "eligibility-owner" in
  let not_requested =
    submit_eligibility_entry ~base_path ~keeper_name "not-requested-unbound"
  in
  let pending =
    submit_eligibility_entry ~base_path ~keeper_name "pending-unbound"
  in
  summary_update_exn "mark resumable summary pending" (AQ.mark_summary_pending ~id:pending.id);
  let pending = approval_entry_exn pending.id in
  let available =
    submit_eligibility_entry ~base_path ~keeper_name "available-unbound"
  in
  summary_update_exn "mark available summary pending" (AQ.mark_summary_pending ~id:available.id);
  summary_update_exn
    "attach available summary"
    (AQ.attach_summary ~id:available.id eligibility_summary);
  let available = approval_entry_exn available.id in
  let make_bound label after_bind =
    let entry = submit_eligibility_entry ~base_path ~keeper_name label in
    summary_update_exn
      ("mark " ^ label ^ " summary pending")
      (AQ.mark_summary_pending ~id:entry.id);
    let entry = approval_entry_exn entry.id in
    let identity = exact_identity label in
    let entry = bind_exact_entry entry identity in
    after_bind entry identity;
    approval_entry_exn entry.id
  in
  let dispatch_uncertain = make_bound "dispatch-uncertain" (fun _ _ -> ()) in
  let released_before_dispatch =
    make_bound "released-before-dispatch" (fun entry identity ->
      exact_update_exn
        "release exact attempt before dispatch"
        (AQ.release_summary_exact_attempt_before_dispatch
           ~id:entry.id
           ~input_hash:entry.input_hash
           ~sequence:entry.sequence
           ~slot_id:identity.slot_id
           ~call_id:identity.call_id
           ~plan_fingerprint:identity.plan_fingerprint
           ~request_body_sha256:identity.request_body_sha256))
  in
  let quarantined =
    make_bound "quarantined" (fun entry identity ->
      exact_update_exn
        "quarantine exact attempt"
        (AQ.quarantine_summary_exact_attempt
           ~id:entry.id
           ~input_hash:entry.input_hash
           ~sequence:entry.sequence
           ~slot_id:identity.slot_id
           ~call_id:identity.call_id
           ~plan_fingerprint:identity.plan_fingerprint
           ~request_body_sha256:identity.request_body_sha256
           ~cause:AQ.Exact_flow_execution_failed))
  in
  let completed =
    make_bound "completed" (fun entry identity ->
      exact_update_exn
        "complete exact attempt"
        (AQ.complete_summary_exact_attempt
           ~id:entry.id
           ~input_hash:entry.input_hash
           ~sequence:entry.sequence
           ~slot_id:identity.slot_id
           ~call_id:identity.call_id
           ~plan_fingerprint:identity.plan_fingerprint
           ~request_body_sha256:identity.request_body_sha256
           ~summary:
             { eligibility_summary with
               model_run_id = identity.call_id
             }))
  in
  let check_ready label expected entry =
    check bool label expected (Gate.For_testing.auto_judge_entry_ready entry)
  in
  check_ready "new unbound judgment is startable" true not_requested;
  check_ready "pending unbound judgment is resumable" true pending;
  check_ready "available judgment does not start a provider worker" false available;
  check_ready "dispatch-uncertain binding is not worker-ready" false dispatch_uncertain;
  check_ready
    "released-before-dispatch binding is not worker-ready"
    false
    released_before_dispatch;
  check_ready "quarantined binding is not worker-ready" false quarantined;
  check_ready "completed binding is finalize-only" false completed;
  (match quarantined.exact_attempt with
   | AQ.Exact_bound { status = AQ.Exact_quarantined AQ.Exact_flow_execution_failed; _ } ->
     ()
   | AQ.Exact_unbound
   | AQ.Exact_bound _ ->
     fail "typed quarantine cause was not persisted");
  (match completed.exact_attempt, completed.summary_status with
   | AQ.Exact_bound { status = AQ.Exact_completed; _ }, AQ.Summary_available _ -> ()
   | _ -> fail "exact completion did not atomically persist its available summary");
  let other_owner =
    submit_eligibility_entry ~base_path ~keeper_name:"other-keeper" "other-owner"
  in
  let ready =
    Gate.For_testing.ready_auto_judges_for_owner
      ~base_path
      ~keeper_name
      (not_requested
       :: pending
       :: available
       :: other_owner
       :: [ dispatch_uncertain; released_before_dispatch; quarantined; completed ])
  in
  check int "operator recovery queues only two worker-ready entries" 2 (List.length ready);
  check (list string) "operator recovery predicate preserves owner FIFO"
    [ not_requested.id; pending.id ]
    (List.map (fun (entry : AQ.pending_approval) -> entry.id) ready)
;;

let test_available_judgments_finalize_without_worker () =
  with_gate_fixture @@ fun base_path ->
  let keeper_name = "available-finalize" in
  let unbound = submit_eligibility_entry ~base_path ~keeper_name "unbound" in
  summary_update_exn "mark unbound summary pending" (AQ.mark_summary_pending ~id:unbound.id);
  summary_update_exn
    "attach unbound decisive summary"
    (AQ.attach_summary ~id:unbound.id eligibility_summary);
  let completed = submit_eligibility_entry ~base_path ~keeper_name "completed" in
  summary_update_exn
    "mark completed summary pending"
    (AQ.mark_summary_pending ~id:completed.id);
  let completed = approval_entry_exn completed.id in
  let identity = exact_identity "restart-completed" in
  let completed = bind_exact_entry completed identity in
  exact_update_exn
    "complete restart-finalizable exact attempt"
    (AQ.complete_summary_exact_attempt
       ~id:completed.id
       ~input_hash:completed.input_hash
       ~sequence:completed.sequence
       ~slot_id:identity.slot_id
       ~call_id:identity.call_id
       ~plan_fingerprint:identity.plan_fingerprint
       ~request_body_sha256:identity.request_body_sha256
       ~summary:
         { eligibility_summary with
           model_run_id = identity.call_id
         });
  AQ.For_testing.reset_runtime_state ();
  (match AQ.install_persistence ~base_path with
   | Ok _ -> ()
   | Error error -> fail (AQ.install_error_to_string error));
  let completed = approval_entry_exn completed.id in
  (match completed.exact_attempt, completed.summary_status with
   | AQ.Exact_bound { status = AQ.Exact_completed; _ }, AQ.Summary_available _ -> ()
   | _ -> fail "completed available judgment did not survive restart");
  check bool "completed available judgment is finalize-only" false
    (Gate.For_testing.auto_judge_entry_ready completed);
  let report = Gate.resume_persisted_auto_judges ~base_path in
  let expected_ids = List.sort String.compare [ unbound.id; completed.id ] in
  check int "two available judgments considered" 2 report.requested;
  check (list string) "available judgments finalized" expected_ids
    (List.sort String.compare report.finalized_ids);
  check (list string) "available judgments start no provider worker" [] report.started_ids;
  check (list string) "available judgments are not skipped" [] report.skipped_ids;
  check int "available judgments have no recovery failure" 0 (List.length report.failures);
  List.iter
    (fun id ->
       check bool ("finalized judgment leaves no pending approval: " ^ id) true
         (Option.is_none (AQ.get_pending_entry ~id)))
    expected_ids
;;

(** A broken optional exact-rule projection must not replace the configured
    Manual, Auto Judge, or invalid-mode decision path. *)
let test_manual_mode_continues_when_rule_store_is_unavailable () =
  with_gate_fixture @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  (match Gate_mode.set config ~actor:"test" Gate_mode.Manual with
   | Ok _ -> ()
   | Error reason -> fail reason);
  write_rules ~base_path (`Assoc [ "invalid", `Bool true ]);
  let before = exact_rule_lookup_failure_count () in
  (match Gate.decide ~keeper_always_allow:false (gate_request ~base_path) with
   | Gate.Deferred { reason = Gate.Human_requested; _ } -> ()
   | Gate.Deferred _ -> fail "Manual mode used the wrong deferred reason"
   | Gate.Allow _ -> fail "Manual mode allowed after exact-rule storage failure"
   | Gate.Unavailable reason ->
     fail
       ("exact-rule storage failure blocked Manual HITL: "
        ^ Gate.unavailable_reason_to_string reason));
  let after = exact_rule_lookup_failure_count () in
  check bool "rule lookup degradation is metered" true (after -. before >= 1.0);
  let audited =
    AQ.read_recent_audit ~base_path ~keeper_name:"keeper" ~n:20 ()
    |> List.exists (fun json ->
      String.equal
        "gate_exact_rule_store_degraded"
        (Safe_ops.json_string ~default:"" "event" json))
  in
  check bool "rule lookup degradation is audited" true audited
;;

let test_auto_judge_continues_when_rule_store_is_unavailable () =
  with_gate_fixture @@ fun base_path ->
  write_rules ~base_path (`Assoc [ "invalid", `Bool true ]);
  match Gate.decide ~keeper_always_allow:false (gate_request ~base_path) with
  | Gate.Deferred
      { reason = (Gate.Judge_requested | Gate.Auto_judge_unavailable _); _ } ->
    ()
  | Gate.Deferred _ -> fail "default Auto Judge used a non-judge deferred reason"
  | Gate.Allow _ -> fail "Auto Judge allowed without a judgment"
  | Gate.Unavailable reason ->
    fail
      ("exact-rule storage failure blocked Auto Judge: "
       ^ Gate.unavailable_reason_to_string reason)
;;

let test_invalid_mode_continues_to_explicit_defer_when_rule_store_is_unavailable () =
  with_gate_fixture @@ fun base_path ->
  let mode_path = Gate_mode.path ~base_path in
  ensure_dir (Filename.dirname mode_path);
  Out_channel.with_open_text mode_path (fun channel ->
    output_string channel {|{"mode":"unsupported"}|});
  write_rules ~base_path (`Assoc [ "invalid", `Bool true ]);
  match Gate.decide ~keeper_always_allow:false (gate_request ~base_path) with
  | Gate.Deferred { reason = Gate.Mode_state_invalid detail; _ } ->
    check bool "invalid mode detail is explicit" true (String.trim detail <> "")
  | Gate.Deferred _ -> fail "invalid mode used the wrong deferred reason"
  | Gate.Allow _ -> fail "invalid mode allowed after rule storage failure"
  | Gate.Unavailable reason ->
    fail
      ("exact-rule storage failure hid the invalid mode: "
       ^ Gate.unavailable_reason_to_string reason)
;;

let test_gate_allows_unexpired_exact_rule () =
  with_gate_fixture @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  (match Gate_mode.set config ~actor:"test" Gate_mode.Manual with
   | Ok _ -> ()
   | Error reason -> fail reason);
  let input = `Assoc [ "target", `String "exact" ] in
  let rule, _ =
    upsert_with_expiry_exn
      ~base_path
      ~input
      ~expires_at:(Unix.gettimeofday () +. 3600.0)
  in
  match Gate.decide ~keeper_always_allow:false (gate_request ~base_path) with
  | Gate.Allow { source = Gate.Exact_always_rule rule_id } ->
    check string "unexpired exact rule id" rule.id rule_id
  | Gate.Allow _ -> fail "Gate used a broader Always Allowed source"
  | Gate.Deferred _ -> fail "unexpired exact rule unexpectedly deferred"
  | Gate.Unavailable reason -> fail (Gate.unavailable_reason_to_string reason)
;;

(** An expired exact rule must not authorize: the Gate falls back to the
    configured mode and the exclusion is audited. *)
let test_gate_defers_and_observes_expired_exact_rule () =
  with_gate_fixture @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  (match Gate_mode.set config ~actor:"test" Gate_mode.Manual with
   | Ok _ -> ()
   | Error reason -> fail reason);
  let input = `Assoc [ "target", `String "exact" ] in
  let rule, _ =
    upsert_with_expiry_exn
      ~base_path
      ~input
      ~expires_at:(Unix.gettimeofday () -. 60.0)
  in
  (match Gate.decide ~keeper_always_allow:false (gate_request ~base_path) with
   | Gate.Deferred { reason = Gate.Human_requested; _ } -> ()
   | Gate.Deferred _ -> fail "expired exact rule used the wrong deferred reason"
   | Gate.Allow _ -> fail "expired exact rule still authorized the request"
   | Gate.Unavailable reason ->
     fail
       ("expired exact rule blocked Manual HITL: "
        ^ Gate.unavailable_reason_to_string reason));
  let audited =
    AQ.read_recent_audit ~base_path ~keeper_name:"keeper" ~n:20 ()
    |> List.exists (fun json ->
      String.equal
        "gate_exact_rule_expired"
        (Safe_ops.json_string ~default:"" "event" json)
      &&
      match Yojson.Safe.Util.member "rule_match" json with
      | `Assoc [ "rule_id", `String rule_id ] -> String.equal rule.id rule_id
      | _ -> false)
  in
  check bool "expired rule exclusion is audited" true audited
;;

let test_keeper_always_allow_does_not_depend_on_rule_store () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       write_rules ~base_path (`Assoc [ "invalid", `Bool true ]);
       match Gate.decide ~keeper_always_allow:true (gate_request ~base_path) with
       | Gate.Allow { source = Gate.Keeper_always_allow } -> ()
       | Gate.Allow _ -> fail "unexpected Always Allowed source"
       | Gate.Deferred _ -> fail "Keeper Always Allowed unexpectedly deferred"
       | Gate.Unavailable reason -> fail (Gate.unavailable_reason_to_string reason))
;;

let test_workspace_always_allow_does_not_depend_on_rule_store () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       (match Gate_mode.set config ~actor:"test" Gate_mode.Always_allow with
        | Ok _ -> ()
        | Error reason -> fail reason);
       write_rules ~base_path (`Assoc [ "invalid", `Bool true ]);
       match Gate.decide ~keeper_always_allow:false (gate_request ~base_path) with
       | Gate.Allow { source = Gate.Workspace_always_allow } -> ()
       | Gate.Allow _ -> fail "unexpected Always Allowed source"
       | Gate.Deferred _ -> fail "workspace Always Allowed unexpectedly deferred"
       | Gate.Unavailable reason -> fail (Gate.unavailable_reason_to_string reason))
;;

let () =
  run
    "Keeper_approval_queue_rules"
    [ ( "Gate eligibility"
      , [ test_case
            "Auto Judge worker eligibility is status-exact"
            `Quick
            test_gate_auto_judge_worker_eligibility_ssot
        ; test_case
            "available judgments finalize without worker"
            `Quick
            test_available_judgments_finalize_without_worker
        ] )
    ; ( "exact rules"
      , [ test_case
            "matches only complete exact request"
            `Quick
            test_rule_matches_only_complete_exact_request
        ; test_case "idempotent upsert" `Quick test_equivalent_upsert_is_idempotent
        ; test_case
            "Gate consumes exact persisted rule"
            `Quick
            test_gate_allows_only_the_exact_persisted_rule
        ; test_case
            "unexpired rule matches with injected now"
            `Quick
            test_unexpired_rule_matches_with_injected_now
        ; test_case
            "expired rule is reported and retained"
            `Quick
            test_expired_rule_is_reported_and_retained
        ; test_case
            "rule without expiry matches at any now"
            `Quick
            test_rule_without_expiry_matches_at_any_now
        ; test_case
            "Gate allows unexpired exact rule"
            `Quick
            test_gate_allows_unexpired_exact_rule
        ; test_case
            "Gate defers and audits expired exact rule"
            `Quick
            test_gate_defers_and_observes_expired_exact_rule
        ; test_case
            "unsupported persisted shape is explicit"
            `Quick
            test_unknown_persisted_shape_is_reported_and_rejected
        ; test_case
            "duplicate persisted rules reject whole store"
            `Quick
            test_duplicate_persisted_rules_reject_whole_store
        ; test_case
            "Manual mode survives exact-rule storage failure"
            `Quick
            test_manual_mode_continues_when_rule_store_is_unavailable
        ; test_case
            "Auto Judge survives exact-rule storage failure"
            `Quick
            test_auto_judge_continues_when_rule_store_is_unavailable
        ; test_case
            "invalid mode remains an explicit defer after rule storage failure"
            `Quick
            test_invalid_mode_continues_to_explicit_defer_when_rule_store_is_unavailable
        ; test_case
            "Keeper Always Allowed is independent of rule storage"
            `Quick
            test_keeper_always_allow_does_not_depend_on_rule_store
        ; test_case
            "workspace Always Allowed is independent of rule storage"
            `Quick
            test_workspace_always_allow_does_not_depend_on_rule_store
        ] )
    ]
;;
