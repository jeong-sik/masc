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
  | Ok matched -> matched
  | Error error -> fail (AQ.rule_store_error_to_string error)
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
         (Option.is_some (find ~base_path ~input:reordered));
       let changed_nonce =
         `Assoc
           [ "target", `String "/workspace/readme.md"
           ; "payload", `Assoc [ "body", `String "hello"; "nonce", `Int 8 ]
           ]
       in
       check bool "no request field is discarded" true
         (Option.is_none (find ~base_path ~input:changed_nonce));
       check bool "different operation identity cannot match" true
         (Option.is_none
            (match
               AQ.find_matching_rule
                 ~base_path
                 ~keeper_name:"keeper"
                 ~tool_name:"another-effect"
                 ~input
                 ()
             with
             | Ok matched -> matched
             | Error error -> fail (AQ.rule_store_error_to_string error))))
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
    (fun () -> f base_path)
;;

let exact_rule_lookup_failure_count () =
  Masc.Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:[ "keeper", "keeper"; "site", "exact_rule_lookup" ]
    ()
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
    [ ( "exact rules"
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
