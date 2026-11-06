open Alcotest

module AQ = Masc.Keeper_approval_queue
module Rules = Masc.Keeper_approval_queue_rules
module Rule_types = Keeper_approval_queue_rules_types
module Gate = Masc.Keeper_gate
module Gate_mode = Masc.Keeper_gate_mode
module Application_store = Masc.Keeper_approval_rule_application_store
module Queue_codec = Masc.Keeper_approval_queue_codec

let audit_rows_exn = function
  | Ok rows -> rows
  | Error error -> Alcotest.fail (Keeper_approval.Audit.read_error_to_string error)
;;

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

let upsert_exn ~base_path ~resolution_sequence ~input =
  match
    Rules.upsert_rule
      ~base_path
      ~keeper_name:"keeper"
      ~tool_name:"external-effect"
      ~input
      ~source_approval_id:("test-approval-" ^ Masc.Keeper_approval_request_fingerprint.request_fingerprint input)
      ~resolution_sequence
      ~expires_at:None
      ()
  with
  | Ok (Rules.Applied { rule; disposition }) -> rule, disposition
  | Ok (Rules.Already_applied (Some rule)) -> rule, Rules.Existing
  | Ok (Rules.Already_applied None) -> fail "fixture approval's rule was deleted"
  | Ok (Rules.Superseded _) -> fail "fixture approval was superseded"
  | Error error -> fail (Rule_types.rule_store_error_to_string error)
;;

let find ~base_path ~input =
  match
    Rules.find_matching_rule
      ~base_path
      ~keeper_name:"keeper"
      ~tool_name:"external-effect"
      ~input
      ()
  with
  | Ok lookup -> lookup
  | Error error -> fail (Rule_types.rule_store_error_to_string error)
;;

let find_active_opt ~base_path ~input =
  match find ~base_path ~input with
  | Rule_types.Rule_match_active matched -> Some matched
  | Rule_types.Rule_match_expired _ | Rule_types.Rule_match_absent -> None
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
       let _rule, created = upsert_exn ~base_path ~resolution_sequence:1 ~input in
       check bool "created" true (created = Rules.Created);
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
            Rules.find_matching_rule
              ~base_path
              ~keeper_name:"keeper"
              ~tool_name:"another-effect"
              ~input
              ()
          with
          | Ok Rule_types.Rule_match_absent -> true
          | Ok (Rule_types.Rule_match_active _ | Rule_types.Rule_match_expired _) -> false
          | Error error -> fail (Rule_types.rule_store_error_to_string error)))
;;

let test_equivalent_upsert_is_idempotent () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "request", `String "exact" ] in
       let first, first_created = upsert_exn ~base_path ~resolution_sequence:1 ~input in
       let second, second_created = upsert_exn ~base_path ~resolution_sequence:1 ~input in
       check bool "first created" true (first_created = Rules.Created);
       check bool "second reused" true (second_created = Rules.Existing);
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
       let rule, _ = upsert_exn ~base_path ~resolution_sequence:1 ~input in
       let request : Gate.request =
         { keeper_name = "keeper"
         ; operation = "external-effect"
         ; call_summary = None
         ; input
         ; base_path
         ; sandbox_profile = None
         ; causal_context = None
         ; task_id = None
         ; continuation_channel = None
         }
       in
       match Gate.decide ~keeper_always_allow:false request with
       | Gate.Allow { source = Gate.Exact_always_rule rule_id; _ } ->
         check string "exact rule id" rule.id rule_id
       | Gate.Allow _ -> fail "Gate used a broader Always Allowed source"
       | Gate.Deferred _ -> fail "exact Always Allowed rule unexpectedly deferred"
       | Gate.Unavailable reason ->
         fail (Gate.unavailable_reason_to_string reason))
;;

let upsert_with_expiry_exn ~base_path ~input ~expires_at =
  match
    Rules.upsert_rule
      ~base_path
      ~keeper_name:"keeper"
      ~tool_name:"external-effect"
      ~input
      ~source_approval_id:("test-approval-" ^ Masc.Keeper_approval_request_fingerprint.request_fingerprint input)
      ~resolution_sequence:1
      ~expires_at:(Some expires_at)
      ()
  with
  | Ok (Rules.Applied { rule; disposition }) -> rule, disposition
  | Ok (Rules.Already_applied (Some rule)) -> rule, Rules.Existing
  | Ok (Rules.Already_applied None) -> fail "fixture approval's rule was deleted"
  | Ok (Rules.Superseded _) -> fail "fixture approval was superseded"
  | Error error -> fail (Rule_types.rule_store_error_to_string error)
;;

let find_at ~base_path ~input ~now =
  match
    Rules.find_matching_rule
      ~base_path
      ~keeper_name:"keeper"
      ~tool_name:"external-effect"
      ~input
      ~now
      ()
  with
  | Ok lookup -> lookup
  | Error error -> fail (Rule_types.rule_store_error_to_string error)
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
       check bool "created" true (created = Rules.Created);
       check (option (float 0.0)) "expiry persisted on rule" (Some 2000.0)
         rule.expires_at;
       match find_at ~base_path ~input ~now:1999.0 with
       | Rule_types.Rule_match_active matched ->
         check string "unexpired rule matches" rule.id matched.rule_id
       | Rule_types.Rule_match_expired _ -> fail "unexpired rule reported as expired"
       | Rule_types.Rule_match_absent -> fail "unexpired rule did not match")
;;

let test_expired_rule_is_reported_and_retained () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "request", `String "exact" ] in
       let rule, _ = upsert_with_expiry_exn ~base_path ~input ~expires_at:2000.0 in
       (match find_at ~base_path ~input ~now:2000.0 with
        | Rule_types.Rule_match_expired matched ->
          check string "expiry boundary is expired" rule.id matched.rule_id
        | Rule_types.Rule_match_active _ -> fail "expired rule still matched"
        | Rule_types.Rule_match_absent -> fail "expired rule must be reported, not absent");
       (match find_at ~base_path ~input ~now:2001.0 with
        | Rule_types.Rule_match_expired matched ->
          check string "after expiry is expired" rule.id matched.rule_id
        | Rule_types.Rule_match_active _ -> fail "expired rule still matched"
        | Rule_types.Rule_match_absent -> fail "expired rule must be reported, not absent");
       let stored =
         match Rules.list_rules ~base_path () with
         | Ok rules -> rules
         | Error error -> fail (Rule_types.rule_store_error_to_string error)
       in
       check bool "expired rule is retained for operator cleanup" true
         (List.exists (fun (stored : Rule_types.approval_rule) ->
            String.equal stored.id rule.id && stored.expires_at = Some 2000.0)
            stored))
;;

let test_rule_without_expiry_matches_at_any_now () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "request", `String "exact" ] in
       let rule, _ = upsert_exn ~base_path ~resolution_sequence:1 ~input in
       check (option (float 0.0)) "no expiry by default" None rule.expires_at;
       match find_at ~base_path ~input ~now:1e12 with
       | Rule_types.Rule_match_active matched ->
         check string "rule without expiry stays active" rule.id matched.rule_id
       | Rule_types.Rule_match_expired _ -> fail "rule without expiry reported as expired"
       | Rule_types.Rule_match_absent -> fail "rule without expiry did not match")
;;

let test_reapproval_applies_each_requested_expiry_option () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "request", `String "renewal" ] in
       let apply ~created_by ~source_approval_id ~resolution_sequence expires_at =
         match
           Rules.upsert_rule
             ~base_path ~keeper_name:"keeper" ~tool_name:"external-effect" ~input
             ~created_by ~source_approval_id ~resolution_sequence ~expires_at ()
         with
         | Ok (Rules.Applied { rule; disposition }) -> rule, disposition
         | Ok (Rules.Already_applied _ | Rules.Superseded _) -> fail "new fixture approval was already settled"
         | Error error -> fail (Rule_types.rule_store_error_to_string error)
       in
       let original, disposition =
         apply ~created_by:"original-author" ~source_approval_id:"original-approval" ~resolution_sequence:1
           (Some 2000.0)
       in
       check bool "initial finite rule created" true (disposition = Rules.Created);
       let previous = ref original.expires_at in
       List.iteri
         (fun index (label, requested, changed) ->
            let rule, disposition =
              apply ~created_by:"renewing-operator" ~source_approval_id:("later-approval-" ^ label)
                ~resolution_sequence:(index + 2)
                requested
            in
            (match disposition, changed with
             | Rules.Existing, false -> ()
             | Rules.Renewed { previous_expires_at }, true ->
               check (option (float 0.0)) (label ^ " previous expiry") !previous
                 previous_expires_at
             | Rules.Created, _ | Rules.Existing, true | Rules.Renewed _, false ->
               fail (label ^ " returned the wrong typed disposition"));
            check string (label ^ " stable rule identity") original.id rule.id;
            check (float 0.0) (label ^ " original creation time") original.created_at
              rule.created_at;
            check (option string) (label ^ " original author") original.created_by
              rule.created_by;
            check (option string) (label ^ " original approval") original.source_approval_id
              rule.source_approval_id;
            (match Rules.list_rules ~base_path () with
             | Ok [ stored ] ->
               check string (label ^ " one persisted identity") original.id stored.id;
               check (option (float 0.0)) (label ^ " exact persisted expiry") requested
                 stored.expires_at
             | Ok _ -> fail (label ^ " duplicated or lost the rule")
             | Error error -> fail (Rule_types.rule_store_error_to_string error));
            previous := requested)
         [ "equal finite", Some 2000.0, false
         ; "later finite", Some 3000.0, true
         ; "earlier past finite", Some 1500.0, true
         ; "finite to permanent", None, true
         ; "equal permanent", None, false
         ; "permanent to finite", Some 2500.0, true
         ])
;;

let apply_rule_approval ~base_path ~approval_id ~resolution_sequence ~expires_at =
  Rules.upsert_rule ~base_path ~keeper_name:"keeper" ~tool_name:"external-effect"
    ~input:(`Assoc [ "request", `String "application-retry" ])
    ~created_by:("actor-" ^ approval_id) ~source_approval_id:approval_id ~resolution_sequence ~expires_at ()
;;

let application_result_exn = function
  | Ok result -> result
  | Error error -> fail (Rule_types.rule_store_error_to_string error)
;;

let application_rule_exn = function
  | Rules.Applied { rule; _ } | Rules.Already_applied (Some rule) -> rule
  | Rules.Already_applied None -> fail "expected a present rule"
  | Rules.Superseded _ -> fail "expected an applied rule"
;;

let read_application_store ~base_path =
  let json = Yojson.Safe.from_file (Rules.rules_path ~base_path ()) in
  match Application_store.of_yojson json with
  | Ok store -> store
  | Error reason -> fail reason
;;

let with_stored_rules_json store entries =
  match Application_store.to_yojson store with
  | `Assoc fields -> `Assoc (("rules", `List entries) :: List.remove_assoc "rules" fields)
  | _ -> fail "canonical application store must be an object"
;;

let test_rule_application_retries_never_rollback_or_resurrect () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let apply id sequence expiry = apply_rule_approval ~base_path ~approval_id:id ~resolution_sequence:sequence ~expires_at:expiry
      |> application_result_exn in
    let first = apply "approval-A" 1 (Some 1000.0) |> application_rule_exn in
    let newer = apply "approval-B" 2 (Some 2000.0) |> application_rule_exn in
    check string "renewal retains identity" first.id newer.id;
    List.iter (fun (id, sequence, expiry) ->
      match apply id sequence (Some expiry) with
      | Rules.Already_applied (Some current) ->
        check (option (float 0.0)) "retry reads current expiry without rollback"
          (Some 2000.0) current.expires_at
      | Rules.Applied _ | Rules.Superseded _ | Rules.Already_applied None -> fail "exact retry was reapplied")
      [ "approval-A", 1, 1000.0; "approval-B", 2, 2000.0; "approval-A", 1, 1000.0 ];
    (match apply_rule_approval ~base_path ~approval_id:"approval-A" ~resolution_sequence:1 ~expires_at:None with
     | Error _ -> ()
     | Ok _ -> fail "same approval id changed its bound expiry");
    List.iter (fun (keeper_name, tool_name, input, created_by) ->
      match Rules.upsert_rule ~base_path ~keeper_name ~tool_name ~input ~created_by
        ~source_approval_id:"approval-A" ~resolution_sequence:1 ~expires_at:(Some 1000.0) () with
      | Error _ -> ()
      | Ok _ -> fail "same approval id changed its bound actor or request identity")
      [ "another-keeper", "external-effect",
          `Assoc [ "request", `String "application-retry" ], "actor-approval-A"
      ; "keeper", "another-effect",
          `Assoc [ "request", `String "application-retry" ], "actor-approval-A"
      ; "keeper", "external-effect", `Assoc [ "request", `String "changed" ],
          "actor-approval-A"
      ; "keeper", "external-effect",
          `Assoc [ "request", `String "application-retry" ], "another-actor" ];
    (match Rules.delete_rule ~base_path ~id:first.id () with
     | Ok _ -> ()
     | Error error -> fail (Rule_types.rule_store_error_to_string error));
    List.iter (fun (id, sequence, expiry) -> match apply id sequence expiry with
      | Rules.Already_applied None -> ()
      | Rules.Applied _ | Rules.Superseded _ | Rules.Already_applied (Some _) ->
        fail "retained delivery recreated a deleted rule")
      [ "approval-B", 2, Some 2000.0; "approval-A", 1, Some 1000.0 ];
    let stored = read_application_store ~base_path in
    check int "deleted permission stays absent" 0 (List.length stored.rules);
    check int "deletion retains exact receipts" 2 (List.length stored.applications);
    let current = apply "approval-C" 3 None |> application_rule_exn in
    check (option (float 0.0)) "genuine new approval may create permanent rule" None
      current.expires_at)
;;

let test_equal_expiry_witness_survives_reopen () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let apply id sequence expiry = apply_rule_approval ~base_path ~approval_id:id ~resolution_sequence:sequence ~expires_at:expiry
      |> application_result_exn in
    (* The subsequent reopened reads establish the committed prefix. *)
    ignore (apply "approval-A" 1 (Some 1000.0) : Rules.rule_upsert_result);
    (match apply "approval-A" 1 (Some 1000.0) with
     | Rules.Already_applied (Some _) -> ()
     | Rules.Applied _ | Rules.Superseded _ | Rules.Already_applied None -> fail "creation was replayed");
    (match apply "approval-B" 2 (Some 1000.0) with
     | Rules.Applied { disposition = Rules.Existing; _ } -> ()
     | Rules.Applied { disposition = (Rules.Created | Rules.Renewed _); _ }
     | Rules.Already_applied _ | Rules.Superseded _ -> fail "new equal-expiry approval was not witnessed");
    let json = Yojson.Safe.from_file (Rules.rules_path ~base_path ()) in
    check int "new writes use canonical envelope" 1
      Yojson.Safe.Util.(json |> member "schema_version" |> to_int);
    check int "equal expiry records its application" 2
      (List.length (read_application_store ~base_path).applications);
    (* The following retry/readback is the assertion for this intervening approval. *)
    ignore (apply "approval-C" 3 (Some 2000.0) : Rules.rule_upsert_result);
    match apply "approval-B" 2 (Some 1000.0) with
    | Rules.Already_applied (Some current) ->
      check (option (float 0.0)) "equal-expiry approval cannot later roll back"
        (Some 2000.0) current.expires_at
    | Rules.Applied _ | Rules.Superseded _ | Rules.Already_applied None -> fail "equal-expiry receipt was lost")
;;

let test_rule_and_application_commit_atomically_across_failed_ack () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    (* Establish the persisted prefix whose atomicity the failing writes must preserve. *)
    ignore (apply_rule_approval ~base_path ~approval_id:"approval-A" ~resolution_sequence:1 ~expires_at:(Some 1000.0)
      |> application_result_exn : Rules.rule_upsert_result);
    let invoke save = Rules.For_testing.upsert_rule_with_save ~save
      ~base_path ~keeper_name:"keeper" ~tool_name:"external-effect"
      ~input:(`Assoc [ "request", `String "application-retry" ])
      ~created_by:"actor-approval-B" ~source_approval_id:"approval-B" ~resolution_sequence:2
      ~expires_at:(Some 2000.0) () in
    let failed_ack ~base_path _store = Error
      { Rule_types.path = Rules.rules_path ~base_path (); reason = "fixture lost write ack" } in
    (match invoke failed_ack with Error _ -> () | Ok _ -> fail "failed write was accepted");
    let before = read_application_store ~base_path in
    check int "failed write adds no receipt" 1 (List.length before.applications);
    check (option (float 0.0)) "failed write preserves rule" (Some 1000.0)
      (List.hd before.rules).expires_at;
    let commit_then_lose_ack ~base_path store =
      match Rules.For_testing.save_rule_store ~base_path store with
      | Error _ as error -> error
      | Ok () -> failed_ack ~base_path store in
    (match invoke commit_then_lose_ack with
     | Error _ -> () | Ok _ -> fail "lost acknowledgment was hidden");
    let after = read_application_store ~base_path in
    check int "completed atomic write contains receipt" 2 (List.length after.applications);
    check (option (float 0.0)) "completed atomic write contains rule" (Some 2000.0)
      (List.hd after.rules).expires_at;
    match apply_rule_approval ~base_path ~approval_id:"approval-B" ~resolution_sequence:2 ~expires_at:(Some 2000.0)
      |> application_result_exn with
    | Rules.Already_applied (Some rule) ->
      check (option (float 0.0)) "retry observes committed value" (Some 2000.0) rule.expires_at
    | Rules.Applied _ | Rules.Superseded _ | Rules.Already_applied None -> fail "lost ack caused application replay")
;;

let test_delayed_first_application_cannot_overwrite_later_resolution () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let apply id sequence expiry = apply_rule_approval ~base_path ~approval_id:id
      ~resolution_sequence:sequence ~expires_at:(Some expiry) |> application_result_exn in
    (* These orders are durable resolution commits, independently of submit order. *)
    let original = apply "approval-A" 1 1000.0 |> application_rule_exn in
    let fail_before_commit ~base_path _store = Error
      { Rule_types.path = Rules.rules_path ~base_path (); reason = "fixture write failed" } in
    let fail_write id sequence expiry =
      match Rules.For_testing.upsert_rule_with_save ~save:fail_before_commit
        ~base_path ~keeper_name:"keeper" ~tool_name:"external-effect"
        ~input:(`Assoc [ "request", `String "application-retry" ])
        ~created_by:("actor-" ^ id) ~source_approval_id:id ~resolution_sequence:sequence
        ~expires_at:(Some expiry) () with
      | Error _ -> () | Ok _ -> fail "fixture unexpectedly wrote the rule" in
    fail_write "approval-B" 2 2000.0;
    let current = apply "approval-C" 3 3000.0 |> application_rule_exn in
    check string "successful renewal retains rule id" original.id current.id;
    List.iter (fun () -> match apply "approval-B" 2 2000.0 with
      | Rules.Superseded (Some rule) ->
        check (option (float 0.0)) "delayed first application cannot roll back C"
          (Some 3000.0) rule.expires_at
      | Rules.Applied _ | Rules.Already_applied _ | Rules.Superseded None ->
        fail "older decision was not explicitly superseded") [ (); () ];
    (* A newly resolved older pending request still has a fresh resolution order. *)
    let later = apply "older-pending-first-resolved-now" 4 2500.0 |> application_rule_exn in
    check (option (float 0.0)) "fresh resolution applies its requested earlier expiry"
      (Some 2500.0) later.expires_at;
    fail_write "approval-E" 5 3500.0;
    let latest = apply "approval-F" 6 4000.0 |> application_rule_exn in
    (match Rules.delete_rule ~base_path ~id:latest.id () with
     | Ok _ -> () | Error error -> fail (Rule_types.rule_store_error_to_string error));
    match apply "approval-E" 5 3500.0 with
    | Rules.Superseded None ->
      check int "deleted permission remains absent after delayed first application" 0
        (List.length (read_application_store ~base_path).rules)
    | Rules.Applied _ | Rules.Already_applied _ | Rules.Superseded (Some _) ->
      fail "delayed decision resurrected deleted permission")
;;

let test_application_identity_is_scoped_to_its_workspace_store () =
  let first = temp_dir () in
  let second = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir first; cleanup_dir second) (fun () ->
    List.iter (fun (base_path, expiry) ->
      let rule = apply_rule_approval ~base_path ~approval_id:"same-opaque-approval-id" ~resolution_sequence:1
        ~expires_at:(Some expiry) |> application_result_exn |> application_rule_exn in
      check (option (float 0.0)) "independent workspace keeps its requested expiry"
        (Some expiry) rule.expires_at;
      check int "workspace owns exactly its application" 1
        (List.length (read_application_store ~base_path).applications))
      [ first, 1000.0; second, 2000.0 ])
;;

let test_application_envelope_rejects_missing_or_conflicting_provenance () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    (* The committed fixture supplies the exact rule/receipt pair under test. *)
    ignore (apply_rule_approval ~base_path ~approval_id:"approval-A" ~resolution_sequence:1 ~expires_at:(Some 1000.0)
      |> application_result_exn : Rules.rule_upsert_result);
    let store = read_application_store ~base_path in
    let json = Application_store.to_yojson store in
    let replace key value = match json with
      | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
      | _ -> fail "canonical store must be an object"
    in
    let receipt = match json with
      | `Assoc fields -> (match List.assoc "applications" fields with
          | `List [ receipt ] -> receipt
          | _ -> fail "one canonical receipt expected")
      | _ -> fail "canonical store must be an object"
    in
    let changed_receipt = match receipt with
      | `Assoc fields -> `Assoc (("keeper_name", `String "wrong-keeper")
          :: List.remove_assoc "keeper_name" fields)
      | _ -> fail "receipt must be an object"
    in
    List.iter (fun (label, malformed) ->
      match Application_store.of_yojson malformed with
      | Error _ -> ()
      | Ok _ -> fail (label ^ " was accepted"))
      [ "unknown version", replace "schema_version" (`Int 2)
      ; "rule expiry differs from latest application", with_stored_rules_json store
          (List.map (fun (rule : Rule_types.approval_rule) ->
             Rule_types.approval_rule_to_yojson { rule with expires_at = None }) store.rules)
      ; "bare rule list has no resolution-order authority",
          `List (List.map Rule_types.approval_rule_to_yojson store.rules)
      ; "missing creation receipt", replace "applications" (`List [])
      ; "duplicate application", replace "applications" (`List [ receipt; receipt ])
      ; "conflicting rule identity", replace "applications" (`List [ changed_receipt ])
      ; "missing envelope field", (match json with
          | `Assoc fields -> `Assoc (List.remove_assoc "applications" fields)
          | _ -> fail "canonical store must be an object")
      ; "duplicate envelope field", (match json with
          | `Assoc fields -> `Assoc (("schema_version", `Int 1) :: fields)
          | _ -> fail "canonical store must be an object") ])
;;

let test_resolution_order_wire_refuses_unproven_order () =
  let base_path = "/workspace" in
  let make_delivery id request_sequence resolution_sequence : Queue_codec.persisted_delivery =
    let input = `Assoc [ "request", `String id ] in
    let continuation_channel = match Keeper_continuation_channel.keeper ~keeper_name:"keeper" with
      | Ok channel -> channel | Error reason -> fail reason in
    let entry : Rule_types.pending_approval =
      { id; sequence = request_sequence; keeper_name = "keeper"; tool_name = "external-effect"
      ; input; input_hash = Masc.Keeper_approval_request_fingerprint.request_fingerprint input
      ; requested_at = 1.0; turn_id = None; origin = Keeper_approval_origin.unavailable; request_context = None; observation = None
      ; task_id = None; goal_id = None
      ; continuation_channel
      ; audit_base_path = base_path; summary_status = Rule_types.Summary_not_requested
      ; exact_attempt = Rule_types.Exact_unbound
      ; summary_attempt_disposition = Rule_types.Summary_attempt_ready }
    in
    { entry; resolution_sequence; decision = Rule_types.Decision.Approve
    ; source = Rule_types.Human_operator; remember_rule = true; rule_expires_at = Some 2000.0
    ; created_by = Some "operator"; grant_consumed = false; replay_outcome = None }
  in
  let snapshot ~next_sequence deliveries =
    let module SMap = Set_util.StringMap in
    let delivery_map = List.fold_left (fun map (delivery : Queue_codec.persisted_delivery) ->
      SMap.add delivery.entry.id delivery map) SMap.empty deliveries in
    Queue_codec.snapshot_to_yojson ~base_path ~next_sequence ~generation:1
      ~pending_map:SMap.empty ~delivery_map
  in
  let delivery = make_delivery "approval-A" 1 2 in
  let canonical = snapshot ~next_sequence:3 [ delivery ] in
  (match Queue_codec.validate_pending_snapshot ~base_path canonical with
   | Ok () -> () | Error reason -> fail reason);
  let change_deliveries transform = match canonical with
    | `Assoc fields -> `Assoc (("deliveries", `List [ transform
        (Queue_codec.persisted_delivery_to_yojson delivery) ]) :: List.remove_assoc "deliveries" fields)
    | _ -> fail "snapshot must be an object"
  in
  let remove_order = function
    | `Assoc fields -> `Assoc (List.remove_assoc "resolution_sequence" fields)
    | _ -> fail "delivery must be an object" in
  List.iter (fun (label, json) ->
    match Queue_codec.validate_pending_snapshot ~base_path json with
    | Error _ -> () | Ok () -> fail (label ^ " was accepted"))
    [ "missing resolution order", change_deliveries remove_order
    ; "resolution order before request", snapshot ~next_sequence:3 [ make_delivery "approval-A" 1 1 ]
    ; "uncommitted resolution order", snapshot ~next_sequence:2 [ delivery ]
    ; "duplicate resolution orders", snapshot ~next_sequence:4
        [ make_delivery "approval-A" 1 3; make_delivery "approval-B" 2 3 ]
    ; "unsupported prior snapshot", (match canonical with
        | `Assoc fields -> `Assoc (("version", `Int 11) :: List.remove_assoc "version" fields)
        | _ -> fail "snapshot must be an object") ];
  let log = Queue_codec.log_row_to_yojson ~generation:1 ~next_sequence:2
    (Queue_codec.Delivery_upsert delivery) in
  match Queue_codec.log_row_of_yojson ~base_path log with
  | Error _ -> ()
  | Ok _ -> fail "log accepted a resolution order beyond its committed cursor"
;;

let test_origin_dedup_and_retained_delivery_wire () =
  let module Origin = Keeper_approval_origin in
  let module State = Masc.Keeper_approval_queue_state in
  let module SMap = Set_util.StringMap in
  let base_path = "/workspace" in
  let turn n = Ids.Turn_ref.make ~trace_id:"approval-origin" ~absolute_turn:n in
  let origin id n =
    let operation_id = match Keeper_operation_id.of_string id with
      | Ok value -> value | Error reason -> fail reason in
    Origin.direct_operation ~operation_id ~turn_ref:(turn n) in
  let channel id = match Keeper_continuation_channel.dashboard ~thread_id:id with
    | Ok value -> value | Error reason -> fail reason in
  let input = `Assoc ["target", `String "same-effect"] in
  let original_origin = origin "operation-a" 1 in
  let entry : Rule_types.pending_approval =
    { id = "approval-a"; sequence = 1; keeper_name = "keeper"; tool_name = "external-effect"
    ; input; input_hash = Masc.Keeper_approval_request_fingerprint.request_fingerprint input
    ; requested_at = 1.0; turn_id = Some 1; origin = original_origin
    ; request_context = Some (`Assoc ["private", `String "summary input"]); observation = None
    ; task_id = None; goal_id = None; continuation_channel = channel "surface-a"
    ; audit_base_path = base_path; summary_status = Rule_types.Summary_not_requested
    ; exact_attempt = Rule_types.Exact_unbound
    ; summary_attempt_disposition = Rule_types.Summary_attempt_ready } in
  let pending = SMap.singleton entry.id entry in
  let lookup ?(continuation_channel=entry.continuation_channel) origin =
    State.find_pending_id_in_map pending ~base_path ~keeper_name:entry.keeper_name
      ~tool_name:entry.tool_name ~input_hash:entry.input_hash ~origin
      ~task_id:None ~goal_id:None ~continuation_channel in
  check (option string) "same logical request resumes without new approval" (Some entry.id)
    (lookup (origin "operation-a" 2));
  check (option string) "another direct request stays separate" None
    (lookup (origin "operation-b" 1));
  check (option string) "another reply surface stays separate" None
    (lookup ~continuation_channel:(channel "surface-b") original_origin);
  check string "pending entry keeps its original physical witness"
    (Ids.Turn_ref.to_string (turn 1))
    (match (SMap.find entry.id pending).origin.turn_ref with
     | Some value -> Ids.Turn_ref.to_string value | None -> fail "lost original turn");
  let board_origin hash post n =
    let source = match Origin.admitted_source ~snapshot_ref:(String.make 64 hash)
        ~admitted_revision:1L ~board_post_id:(Some post) with
      | Ok value -> value | Error reason -> fail reason in
    match Origin.admitted_sources ~sources:[source] ~turn_ref:(turn n) with
    | Ok value -> value | Error reason -> fail reason in
  let board_entry = {entry with origin = board_origin 'a' "post-a" 1} in
  let find_board origin = State.find_pending_id_in_map (SMap.singleton entry.id board_entry)
      ~base_path ~keeper_name:entry.keeper_name ~tool_name:entry.tool_name
      ~input_hash:entry.input_hash ~origin ~task_id:None ~goal_id:None
      ~continuation_channel:entry.continuation_channel in
  check (option string) "Board resume folds" (Some entry.id) (find_board (board_origin 'a' "post-a" 2));
  check (option string) "distinct Board request does not fold" None (find_board (board_origin 'b' "post-b" 1));
  let delivery : Queue_codec.persisted_delivery =
    { entry; resolution_sequence = 2; decision = Rule_types.Decision.Approve
    ; source = Rule_types.Human_operator; remember_rule = false; rule_expires_at = None
    ; created_by = None; grant_consumed = false; replay_outcome = None } in
  let encoded = Queue_codec.persisted_delivery_to_yojson delivery in
  let entry_json = Yojson.Safe.Util.member "entry" encoded in
  check bool "resolved delivery omits private request context" true
    (Yojson.Safe.Util.member "request_context" entry_json = `Null);
  let log = Queue_codec.log_row_to_yojson ~generation:1 ~next_sequence:3
      (Queue_codec.Delivery_upsert delivery) in
  let restored = match Queue_codec.log_row_of_yojson ~base_path log with
    | Ok {row = Queue_codec.Delivery_upsert value;_} -> value
    | Ok {row = (Queue_codec.Pending_upsert _ | Queue_codec.Pending_remove _ | Queue_codec.Delivery_remove _);_} -> fail "wrong log row"
    | Error reason -> fail reason in
  check (testable Yojson.Safe.pp Yojson.Safe.equal) "retained delivery keeps exact origin"
    (Origin.to_yojson original_origin) (Origin.to_yojson restored.entry.origin);
  let grant_lookup delivery origin =
    State.find_unconsumed_grant_id_in_deliveries (SMap.singleton entry.id delivery)
      ~base_path ~keeper_name:entry.keeper_name ~tool_name:entry.tool_name
      ~input_hash:entry.input_hash ~origin ~task_id:None ~goal_id:None
      ~continuation_channel:entry.continuation_channel in
  check (option string) "approved effect reuses unconsumed grant" (Some entry.id)
    (grant_lookup restored (origin "operation-a" 2));
  check (option string) "another operation cannot fold onto grant" None
    (grant_lookup restored (origin "operation-b" 2));
  check (option string) "consumed grant never folds" None
    (grant_lookup {restored with grant_consumed = true} original_origin);
  let snapshot = Queue_codec.snapshot_to_yojson ~base_path ~next_sequence:2 ~generation:1
      ~pending_map:pending ~delivery_map:SMap.empty in
  let replace key value = function
    | `Assoc fields -> `Assoc ((key,value) :: List.remove_assoc key fields)
    | _ -> fail "expected object" in
  let entry_json = Queue_codec.pending_entry_to_yojson entry in
  let malformed = match entry_json with
    | `Assoc fields -> `Assoc (List.remove_assoc "origin" fields)
    | _ -> fail "expected entry" in
  (match Queue_codec.pending_entry_of_yojson ~base_path malformed with
   | Error _ -> () | Ok _ -> fail "missing origin was accepted");
  (match Queue_codec.validate_pending_snapshot ~base_path (replace "version" (`Int 12) snapshot) with
   | Error _ -> () | Ok () -> fail "previous format silently invented provenance")
;;

let test_unknown_persisted_shape_is_reported_and_rejected () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "request", `String "exact" ] in
       let rule, _ = upsert_exn ~base_path ~resolution_sequence:1 ~input in
       let store = read_application_store ~base_path in
       let json = Rule_types.approval_rule_to_yojson rule in
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
       write_rules ~base_path (with_stored_rules_json store [ json; extended ]);
       (match Rules.list_rules ~base_path () with
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

let with_rule_id id (rule : Rule_types.approval_rule) = { rule with id }

let test_duplicate_persisted_rules_reject_whole_store () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let first, _ =
         upsert_exn ~base_path ~resolution_sequence:1 ~input:(`Assoc [ "request", `String "first" ])
       in
       let second, _ =
         upsert_exn ~base_path ~resolution_sequence:2 ~input:(`Assoc [ "request", `String "second" ])
       in
       let store = read_application_store ~base_path in
       write_rules
         ~base_path
         (with_stored_rules_json store
             [ Rule_types.approval_rule_to_yojson first
             ; Rule_types.approval_rule_to_yojson (with_rule_id first.id second)
             ]);
       (match Rules.list_rules ~base_path () with
        | Ok _ -> fail "duplicate rule ids must fail the whole rules store"
        | Error error ->
          check bool "duplicate id named" true
            (String.starts_with
               ~prefix:"duplicate approval rule id "
               error.reason));
       write_rules
         ~base_path
         (with_stored_rules_json store
             [ Rule_types.approval_rule_to_yojson first
             ; Rule_types.approval_rule_to_yojson (with_rule_id "different-id" first)
             ]);
       match Rules.list_rules ~base_path () with
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
  ; call_summary = None
  ; input = `Assoc [ "target", `String "exact" ]
  ; base_path
  ; sandbox_profile = None
  ; causal_context = None
  ; task_id = None
  ; continuation_channel = None
  }
;;

let with_gate_fixture f =
  let base_path = temp_dir () in
  AQ.For_testing.reset_runtime_state ();
  Keeper_approval.Audit.For_testing.reset_store ();
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      Keeper_approval.Audit.For_testing.reset_store ();
      cleanup_dir base_path)
    (fun () ->
       (match AQ.install_persistence ~base_path with
        | Ok _report -> ()
        | Error error -> fail (Masc.Keeper_approval_queue_result.install_error_to_string error));
       f base_path)
;;

let exact_rule_lookup_failure_count () =
  Masc.Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:[ "keeper", "keeper"; "site", "exact_rule_lookup" ]
    ()
;;

let eligibility_summary : Rule_types.hitl_context_summary =
  { summary_version = 2
  ; generated_at = 1.0
  ; model_run_id = "gate-eligibility-judge"
  ; context_summary = "The exact request is supported by the visible context."
  ; key_questions = []
  ; judgment = Rule_types.Approve
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
  match AQ.For_testing.get_pending_entry_unchecked ~id with
  | Some entry -> entry
  | None -> fail ("pending approval not found: " ^ id)
;;

let submit_eligibility_entry ~base_path ~keeper_name label =
  match
    AQ.submit_pending ~origin:Keeper_approval_origin.unavailable
      ~keeper_name
      ~tool_name:"external-effect"
      ~call_summary:None
      ~input:(`Assoc [ "request", `String label ])
      ~base_path
      ()
  with
  | Ok submission -> approval_entry_exn submission.approval_id
  | Error error -> fail (Masc.Keeper_approval_queue_result.storage_error_to_string error)
;;

let summary_update_exn label = function
  | Ok true -> ()
  | Ok false -> fail (label ^ " did not update the pending approval")
  | Error error -> fail (Masc.Keeper_approval_queue_result.summary_transition_error_to_string error)
;;

let exact_update_exn label = function
  | Ok { Masc.Keeper_approval_queue_result.changed = true; write_outcome = Masc.Keeper_approval_queue_result.Fsync_completed } -> ()
  | Ok { changed = false; write_outcome = Masc.Keeper_approval_queue_result.Fsync_completed } ->
    fail (label ^ " did not update the exact attempt")
  | Ok { write_outcome = Masc.Keeper_approval_queue_result.Visible_sync_unconfirmed detail; _ } ->
    fail (label ^ " returned visible durability uncertainty: " ^ detail)
  | Error error -> fail (Masc.Keeper_approval_queue_result.exact_attempt_error_to_string error)
;;

let exact_identity label =
  { slot_id = "exact-slot-" ^ label
  ; call_id = "exact-call-" ^ label
  ; plan_fingerprint = String.make 64 'b'
  ; request_body_sha256 = String.make 64 'c'
  }
;;

let bind_exact_entry (entry : Rule_types.pending_approval) identity =
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
           ~cause:Rule_types.Exact_flow_execution_failed))
  in
  let cancellation_quarantined =
    make_bound "cancellation-quarantined" (fun entry identity ->
      exact_update_exn
        "quarantine exact attempt by cancellation"
        (AQ.quarantine_summary_exact_attempt
           ~id:entry.id
           ~input_hash:entry.input_hash
           ~sequence:entry.sequence
           ~slot_id:identity.slot_id
           ~call_id:identity.call_id
           ~plan_fingerprint:identity.plan_fingerprint
           ~request_body_sha256:identity.request_body_sha256
           ~cause:Rule_types.Exact_cancellation))
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
let with_exact_status (entry : Rule_types.pending_approval) status =
    match entry.exact_attempt with
    | Rule_types.Exact_bound binding ->
      { entry with
        exact_attempt =
          Rule_types.Exact_bound
            (Rule_types.exact_attempt_binding_with_status binding status)
      }
    | Rule_types.Exact_unbound ->
      fail "bound exact eligibility fixture became unbound"
  in
  let released_recovery_required =
    with_exact_status
      released_before_dispatch
      Rule_types.Exact_released_recovery_required
  in
  let restart_quarantined =
    with_exact_status dispatch_uncertain Rule_types.Exact_restart_quarantined
  in
  let check_ready label expected entry =
    check bool label expected (Gate.For_testing.auto_judge_entry_ready entry)
  in
  check_ready "new unbound judgment is startable" true not_requested;
  check_ready "pending unbound judgment is resumable" true pending;
  check_ready "dispatch-uncertain binding is not worker-ready" false dispatch_uncertain;
  check_ready
    "released-before-dispatch binding is not worker-ready"
    false
    released_before_dispatch;
  check_ready
    "released recovery-required binding is operator-only"
    false
    released_recovery_required;
  check_ready "quarantined binding is not worker-ready" false quarantined;
  check_ready
    "cancellation quarantine is not worker-ready either"
    false
    cancellation_quarantined;
  check_ready
    "restart-quarantined binding is terminal"
    false
    restart_quarantined;
  check_ready "completed binding is finalize-only" false completed;
  (match quarantined.exact_attempt with
   | Rule_types.Exact_bound { status = Rule_types.Exact_quarantined Rule_types.Exact_flow_execution_failed; _ } ->
     ()
   | Rule_types.Exact_unbound
   | Rule_types.Exact_bound _ ->
     fail "typed quarantine cause was not persisted");
  (match completed.exact_attempt, completed.summary_status with
   | Rule_types.Exact_bound { status = Rule_types.Exact_completed; _ }, Rule_types.Summary_available _ -> ()
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
       :: other_owner
       :: [ dispatch_uncertain
          ; released_before_dispatch
          ; released_recovery_required
          ; quarantined
          ; restart_quarantined
          ; cancellation_quarantined
          ; completed
          ])
  in
  (* The window is the FIFO head onwards, bounded by the owner's available
     slots. Every bound shape in the input is excluded, cancellation
     included: a judgment the server died under reached no verdict and
     nothing re-runs it, so the row waits for an operator like any other
     quarantine. *)
  check int "operator recovery exposes the FIFO window" 2 (List.length ready);
  check (list string) "operator recovery starts from the FIFO head in order"
    [ not_requested.id; pending.id ]
    (List.map (fun (entry : Rule_types.pending_approval) -> entry.id) ready)
;;

let test_completed_exact_judgment_finalizes_without_worker () =
  with_gate_fixture @@ fun base_path ->
  let keeper_name = "available-finalize" in
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
   | Error error -> fail (Masc.Keeper_approval_queue_result.install_error_to_string error));
  let completed = approval_entry_exn completed.id in
  (match completed.exact_attempt, completed.summary_status with
   | Rule_types.Exact_bound { status = Rule_types.Exact_completed; _ }, Rule_types.Summary_available _ -> ()
   | _ -> fail "completed available judgment did not survive restart");
  check bool "completed available judgment is finalize-only" false
    (Gate.For_testing.auto_judge_entry_ready completed);
  let report = Gate.resume_persisted_auto_judges ~base_path in
  let expected_ids = [ completed.id ] in
  check int "one completed exact judgment considered" 1 report.requested;
  check (list string) "completed exact judgment finalized" expected_ids
    (List.sort String.compare report.finalized_ids);
  check (list string) "completed exact judgment starts no provider worker" [] report.started_ids;
  check (list string) "completed exact judgment is not skipped" [] report.skipped_ids;
  check int "completed exact judgment has no recovery failure" 0 (List.length report.failures);
  List.iter
    (fun id ->
       check bool ("finalized judgment leaves no pending approval: " ^ id) true
         (Option.is_none (AQ.For_testing.get_pending_entry_unchecked ~id)))
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
    Keeper_approval.Audit.read_recent ~base_path ~keeper_name:"keeper" ~n:20 ()
    |> audit_rows_exn
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
  | Gate.Allow { source = Gate.Exact_always_rule rule_id; _ } ->
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
    Keeper_approval.Audit.read_recent ~base_path ~keeper_name:"keeper" ~n:20 ()
    |> audit_rows_exn
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
       | Gate.Allow { source = Gate.Keeper_always_allow; _ } -> ()
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
       | Gate.Allow { source = Gate.Workspace_always_allow; _ } -> ()
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
            "completed exact judgment finalizes without worker"
            `Quick
            test_completed_exact_judgment_finalizes_without_worker
        ] )
    ; ( "exact rules"
      , [ test_case
            "matches only complete exact request"
            `Quick
            test_rule_matches_only_complete_exact_request
        ; test_case "idempotent upsert" `Quick test_equivalent_upsert_is_idempotent
        ; test_case
            "reapproval persists exact finite and permanent options"
            `Quick
            test_reapproval_applies_each_requested_expiry_option
        ; test_case "retained applications never rollback or resurrect" `Quick
            test_rule_application_retries_never_rollback_or_resurrect
        ; test_case "equal-expiry witnesses survive reopen" `Quick
            test_equal_expiry_witness_survives_reopen
        ; test_case "rule and receipt atomicity after failed ack" `Quick
            test_rule_and_application_commit_atomically_across_failed_ack
        ; test_case "delayed first application respects resolution commit order" `Quick
            test_delayed_first_application_cannot_overwrite_later_resolution
        ; test_case "application receipts belong to their workspace" `Quick
            test_application_identity_is_scoped_to_its_workspace_store
        ; test_case "application envelope rejects conflicting provenance" `Quick
            test_application_envelope_rejects_missing_or_conflicting_provenance
        ; test_case "resolution order wire refuses missing or conflicting authority" `Quick
            test_resolution_order_wire_refuses_unproven_order
        ; test_case "logical origin dedup and retained delivery wire" `Quick
            test_origin_dedup_and_retained_delivery_wire
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
