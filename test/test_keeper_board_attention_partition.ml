module P = Masc.Keeper_board_attention_partition
module A = P.Candidate
module J = Masc.Keeper_board_attention_judgment

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base name f =
  let base_path = Filename.temp_dir name "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let expect_error label = function
  | Error _ -> ()
  | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label
;;

let ledger_lines path =
  Fs_compat.load_file path
  |> String.split_on_char '\n'
  |> List.filter (fun line -> not (String.equal line ""))
;;

let signal post_id : Masc.Board_dispatch.board_signal =
  { kind = Masc.Board_dispatch.Board_post_created
  ; post_id
  ; author = "external-author"
  ; title = "Board update"
  ; content = "Persisted Board evidence"
  ; hearth = Some "hearth-1"
  ; updated_at = Some 42.0
  }
;;

let context name =
  `Assoc
    [ "instructions", `String ("continue " ^ name)
    ; "runtime", `Assoc [ "lane", `String "configured-judge" ]
    ]
;;

let candidate ?(keeper_name = "sangsu") ?(context = context "primary") ~id ~recorded_at () :
  A.candidate
  =
  { candidate_id = id
  ; keeper_name
  ; signal = signal id
  ; judgment_request = `Assoc [ "keeper_context", context ]
  ; recorded_at
  ; status = A.Pending { last_delivery_failure = None }
  }
;;

let provenance
      ?(slot_id = "slot-1")
      ?(call_id = "call-1")
      ?(plan_fingerprint = "plan-1")
      ?(request_body_sha256 = "body-1")
      ()
  : P.exact_provenance
  =
  { slot_id; call_id; plan_fingerprint; request_body_sha256 }
;;

let judgment ?(judged_at = 101.0) (proof : P.exact_provenance) : A.judgment =
  { verdict = { J.decision = J.Relevant; rationale = "react to this Board event" }
  ; slot_id = proof.slot_id
  ; call_id = proof.call_id
  ; plan_fingerprint = proof.plan_fingerprint
  ; request_body_sha256 = proof.request_body_sha256
  ; judged_at
  }
;;

let roots ~base_path candidates =
  ignore
    (ok "ensure roots" (P.ensure_roots ~base_path ~keeper_name:"sangsu" candidates) : int);
  ok "load roots" (P.load ~base_path ~keeper_name:"sangsu")
;;

let claim ~base_path ~worker_epoch ~now =
  match ok "claim next" (P.claim_next ~now ~worker_epoch ~base_path ~keeper_name:"sangsu") with
  | Some partition -> partition
  | None -> Alcotest.fail "expected a Ready partition"
;;

let fsynced label (transition : P.exact_transition) =
  match transition.write_outcome with
  | P.Fsync_completed -> transition.partition
  | P.Visible_sync_unconfirmed detail ->
    Alcotest.failf "%s was visible without confirmed fsync: %s" label detail
;;

let test_roots_are_singleton_deterministic_and_context_exact () =
  with_temp_base "board-attention-partition-roots" @@ fun base_path ->
  let first = candidate ~id:"candidate-first" ~recorded_at:1.0 () in
  let second = candidate ~id:"candidate-second" ~recorded_at:2.0 () in
  let isolated =
    candidate
      ~context:(context "isolated")
      ~id:"candidate-isolated"
      ~recorded_at:3.0
      ()
  in
  let created = roots ~base_path [ second; isolated; first ] in
  Alcotest.(check int) "one root per Pending candidate" 3 (List.length created);
  Alcotest.(check (list string))
    "oldest candidate order is durable"
    [ first.candidate_id; second.candidate_id; isolated.candidate_id ]
    (List.map (fun partition -> partition.P.candidate_id) created);
  List.iter
    (fun partition ->
       match partition.P.state with
       | P.Ready -> ()
       | _ -> Alcotest.fail "new partition was not Ready")
    created;
  Alcotest.(check int)
    "repeated ensure creates nothing"
    0
    (ok
       "repeat ensure"
       (P.ensure_roots
          ~base_path
          ~keeper_name:"sangsu"
          [ first; second; isolated ]));
  let repeated = ok "load repeated roots" (P.load ~base_path ~keeper_name:"sangsu") in
  Alcotest.(check bool) "root creation is idempotent" true (created = repeated);
  expect_error
    "same candidate identity with changed context"
    (P.ensure_roots
       ~base_path
       ~keeper_name:"sangsu"
       [ { first with judgment_request = `Assoc [ "keeper_context", context "changed" ] } ]);
  let primary_key = (List.hd created).P.context_key in
  let isolated_key = (List.hd (List.rev created)).P.context_key in
  Alcotest.(check bool)
    "different exact Keeper contexts do not collapse"
    false
    (A.Context_key.equal primary_key isolated_key)
;;

let test_binding_owns_completion_and_settlement () =
  with_temp_base "board-attention-partition-binding" @@ fun base_path ->
  let pending = candidate ~id:"candidate-bound" ~recorded_at:1.0 () in
  ignore (roots ~base_path [ pending ] : P.t list);
  let owner = P.Worker_epoch.generate () in
  let stranger = P.Worker_epoch.generate () in
  let claimed = claim ~base_path ~worker_epoch:owner ~now:10.0 in
  (match claimed.state with
   | P.Running { progress = P.Unbound; _ } -> ()
   | _ -> Alcotest.fail "claim did not create Running Unbound");
  let proof = provenance () in
  expect_error
    "foreign worker bind"
    (P.bind_before_dispatch
       ~worker_epoch:stranger
       ~base_path
       ~partition:claimed
       ~provenance:proof);
  let bound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:claimed
      ~provenance:proof
    |> ok "bind before dispatch"
    |> fsynced "bind before dispatch"
  in
  (match bound.state with
   | P.Running { progress = P.Bound durable; _ } ->
     Alcotest.(check bool) "opaque proof persisted exactly" true (durable = proof)
   | _ -> Alcotest.fail "partition was not Bound");
  let repeated =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:bound
      ~provenance:proof
    |> ok "repeat exact bind"
  in
  Alcotest.(check bool) "idempotent bind reports no state change" false repeated.changed;
  ignore (fsynced "repeat exact bind" repeated : P.t);
  expect_error
    "conflicting bound provenance"
    (P.bind_before_dispatch
       ~worker_epoch:owner
       ~base_path
       ~partition:bound
       ~provenance:(provenance ~call_id:"call-conflict" ()));
  let item : P.completed_item =
    { candidate_id = claimed.candidate_id; judgment = judgment proof }
  in
  expect_error
    "foreign worker completion"
    (P.complete ~now:11.0 ~worker_epoch:stranger ~base_path ~partition:bound ~item);
  let completed =
    P.complete ~now:11.0 ~worker_epoch:owner ~base_path ~partition:bound ~item
    |> ok "complete"
    |> fsynced "complete"
  in
  (match completed.state with
   | P.Completed { item = persisted; _ } ->
     Alcotest.(check string)
       "exact completion identity persisted"
       claimed.candidate_id
       persisted.candidate_id
   | _ -> Alcotest.fail "partition was not Completed");
  let confirmed_transition =
    ok "confirm completed" (P.confirm_completed ~base_path ~partition:completed)
  in
  Alcotest.(check bool)
    "Completed confirmation is idempotent"
    false
    confirmed_transition.changed;
  let confirmed = fsynced "confirm completed" confirmed_transition in
  Alcotest.(check bool)
    "Completed confirmation retained the exact partition"
    true
    (confirmed = completed);
  let wrong_item =
    { item with
      judgment = judgment (provenance ~call_id:"wrong-completed-call" ())
    }
  in
  let conflicting_completed =
    let wrong_state =
      `Assoc
        [ "kind", `String "completed"
        ; ( "item"
          , `Assoc
              [ "candidate_id", `String wrong_item.candidate_id
              ; "judgment", A.judgment_to_yojson wrong_item.judgment
              ] )
        ; "completed_at", `Float 11.0
        ]
    in
    match P.to_yojson completed with
    | `Assoc fields ->
      let encoded =
        `Assoc
          (List.map
             (fun (key, value) ->
                if String.equal key "state" then key, wrong_state else key, value)
             fields)
      in
      ok "decode conflicting completed fixture" (P.of_yojson encoded)
    | _ -> Alcotest.fail "completed partition fixture was not an object"
  in
  expect_error
    "confirm completed rejects a conflicting item"
    (P.confirm_completed
       ~base_path
       ~partition:conflicting_completed);
  let settled = ok "settle" (P.settle ~now:12.0 ~base_path ~partition:confirmed) in
  let settled_again = ok "settle idempotently" (P.settle ~now:99.0 ~base_path ~partition:settled) in
  Alcotest.(check bool) "settlement is idempotent" true (settled = settled_again)
;;

let test_existing_judgment_completion_is_atomic_and_restart_safe () =
  with_temp_base "board-attention-partition-existing-judgment" @@ fun base_path ->
  let projected_candidate =
    candidate ~id:"candidate-existing" ~recorded_at:1.0 ()
  in
  let bound_candidate = candidate ~id:"candidate-bound-existing" ~recorded_at:2.0 () in
  let advancing_candidate =
    candidate ~id:"candidate-advancing-existing" ~recorded_at:3.0 ()
  in
  ignore
    (roots ~base_path [ advancing_candidate; bound_candidate; projected_candidate ]
      : P.t list);
  let owner = P.Worker_epoch.generate () in
  let stranger = P.Worker_epoch.generate () in
  let projected = claim ~base_path ~worker_epoch:owner ~now:10.0 in
  let projected_proof =
    provenance ~slot_id:"existing-slot" ~call_id:"existing-call" ()
  in
  let projected_item : P.completed_item =
    { candidate_id = projected_candidate.candidate_id
    ; judgment = judgment projected_proof
    }
  in
  expect_error
    "foreign worker existing judgment completion"
    (P.complete_existing_judgment
       ~now:11.0
       ~worker_epoch:stranger
       ~base_path
       ~partition:projected
       ~item:projected_item);
  expect_error
    "existing judgment candidate identity mismatch"
    (P.complete_existing_judgment
       ~now:11.0
       ~worker_epoch:owner
       ~base_path
       ~partition:projected
       ~item:{ projected_item with candidate_id = "candidate-other" });
  expect_error
    "existing judgment invalid provenance"
    (P.complete_existing_judgment
       ~now:11.0
       ~worker_epoch:owner
       ~base_path
       ~partition:projected
       ~item:
         { projected_item with
           judgment = { projected_item.judgment with slot_id = "" }
         });
  let completed =
    P.complete_existing_judgment
      ~now:11.0
      ~worker_epoch:owner
      ~base_path
      ~partition:projected
      ~item:projected_item
    |> ok "complete existing judgment"
    |> fsynced "complete existing judgment"
  in
  let require_projected label partitions =
    match
      List.find_opt
        (fun (partition : P.t) ->
           String.equal partition.candidate_id projected_candidate.candidate_id)
        partitions
    with
    | Some { state = P.Completed { item; completed_at }; _ } ->
      Alcotest.(check bool) (label ^ " exact item") true (item = projected_item);
      Alcotest.(check (float 0.0)) (label ^ " completion time") 11.0 completed_at
    | Some _ -> Alcotest.failf "%s did not retain Completed state" label
    | None -> Alcotest.failf "%s lost the projected partition" label
  in
  require_projected
    "durable roundtrip"
    (ok "load projected judgment" (P.load ~base_path ~keeper_name:"sangsu"));
  Alcotest.(check int)
    "restart does not recover completed existing judgment"
    0
    (ok
       "restart after existing judgment completion"
       (P.recover_for_process_start ~now:12.0 ~base_path ~keeper_name:"sangsu"));
  require_projected
    "restart"
    (ok "load after restart" (P.load ~base_path ~keeper_name:"sangsu"));
  let bound_claim = claim ~base_path ~worker_epoch:owner ~now:13.0 in
  let bound_proof =
    provenance ~slot_id:"bound-existing-slot" ~call_id:"bound-existing-call" ()
  in
  let bound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:bound_claim
      ~provenance:bound_proof
    |> ok "bind existing-judgment rejection fixture"
    |> fsynced "bind existing-judgment rejection fixture"
  in
  expect_error
    "existing judgment rejects Bound"
    (P.complete_existing_judgment
       ~now:14.0
       ~worker_epoch:owner
       ~base_path
       ~partition:bound
       ~item:
         { candidate_id = bound_candidate.candidate_id
         ; judgment = judgment bound_proof
         });
  let advancing_claim = claim ~base_path ~worker_epoch:owner ~now:15.0 in
  let failed =
    provenance ~slot_id:"failed-existing-slot" ~call_id:"failed-existing-call" ()
  in
  let next =
    provenance ~slot_id:"next-existing-slot" ~call_id:"next-existing-call" ()
  in
  let advancing_bound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:advancing_claim
      ~provenance:failed
    |> ok "bind advancing existing-judgment rejection fixture"
    |> fsynced "bind advancing existing-judgment rejection fixture"
  in
  let advancing =
    P.record_before_advance
      ~worker_epoch:owner
      ~base_path
      ~partition:advancing_bound
      ~failed
      ~next
    |> ok "advance existing-judgment rejection fixture"
    |> fsynced "advance existing-judgment rejection fixture"
  in
  expect_error
    "existing judgment rejects Advancing"
    (P.complete_existing_judgment
       ~now:16.0
       ~worker_epoch:owner
       ~base_path
       ~partition:advancing
       ~item:
         { candidate_id = advancing_candidate.candidate_id
         ; judgment = judgment next
         });
  ignore (completed : P.t)
;;

let test_before_advance_is_atomic_and_exact () =
  with_temp_base "board-attention-partition-advance" @@ fun base_path ->
  let pending = candidate ~id:"candidate-advance" ~recorded_at:1.0 () in
  ignore (roots ~base_path [ pending ] : P.t list);
  let owner = P.Worker_epoch.generate () in
  let claimed = claim ~base_path ~worker_epoch:owner ~now:10.0 in
  let failed = provenance ~slot_id:"slot-failed" ~call_id:"call-failed" () in
  let next = provenance ~slot_id:"slot-next" ~call_id:"call-next" () in
  let bound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:claimed
      ~provenance:failed
    |> ok "bind failed attempt"
    |> fsynced "bind failed attempt"
  in
  expect_error
    "before advance requires exact failed binding"
    (P.record_before_advance
       ~worker_epoch:owner
       ~base_path
       ~partition:bound
       ~failed:(provenance ~call_id:"other-call" ())
       ~next);
  expect_error
    "before advance rejects same attempt"
    (P.record_before_advance
       ~worker_epoch:owner
       ~base_path
       ~partition:bound
       ~failed
       ~next:failed);
  let advancing_transition =
    ok
      "record before advance"
      (P.record_before_advance
         ~worker_epoch:owner
         ~base_path
         ~partition:bound
         ~failed
         ~next)
  in
  Alcotest.(check bool) "advance changes durable state" true advancing_transition.changed;
  let advancing = fsynced "record before advance" advancing_transition in
  (match advancing.state with
   | P.Running { progress = P.Advancing durable; _ } ->
     Alcotest.(check bool) "failed proof retained" true (durable.failed = failed);
     Alcotest.(check bool) "next proof retained" true (durable.next = next)
   | _ -> Alcotest.fail "partition was not Advancing");
  let repeated =
    ok
      "repeat before advance"
      (P.record_before_advance
         ~worker_epoch:owner
         ~base_path
         ~partition:advancing
         ~failed
         ~next)
  in
  Alcotest.(check bool) "idempotent advance reports no state change" false repeated.changed;
  ignore (fsynced "repeat before advance" repeated : P.t);
  expect_error
    "advancing can bind only retained next proof"
    (P.bind_before_dispatch
       ~worker_epoch:owner
       ~base_path
       ~partition:advancing
       ~provenance:(provenance ~call_id:"unplanned-call" ()));
  let rebound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:advancing
      ~provenance:next
    |> ok "bind retained next"
    |> fsynced "bind retained next"
  in
  expect_error
    "completion cannot use prior attempt provenance"
    (P.complete
       ~now:11.0
       ~worker_epoch:owner
       ~base_path
       ~partition:rebound
       ~item:{ candidate_id = pending.candidate_id; judgment = judgment failed });
  ignore
    (P.complete
       ~now:11.0
       ~worker_epoch:owner
       ~base_path
       ~partition:rebound
       ~item:{ candidate_id = pending.candidate_id; judgment = judgment next }
     |> ok "complete rebound attempt"
     |> fsynced "complete rebound attempt"
     : P.t)
;;

let test_runtime_transitions_append_then_startup_compacts () =
  with_temp_base "board-attention-partition-append-index" @@ fun base_path ->
  let pending = candidate ~id:"candidate-append" ~recorded_at:1.0 () in
  ignore (roots ~base_path [ pending ] : P.t list);
  let ledger_path = P.For_testing.path ~base_path ~keeper_name:"sangsu" in
  let owner = P.Worker_epoch.generate () in
  let claimed = claim ~base_path ~worker_epoch:owner ~now:10.0 in
  let proof = provenance () in
  let bound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:claimed
      ~provenance:proof
    |> ok "bind append"
    |> fsynced "bind append"
  in
  let completed =
    P.complete
      ~now:11.0
      ~worker_epoch:owner
      ~base_path
      ~partition:bound
      ~item:{ candidate_id = pending.candidate_id; judgment = judgment proof }
    |> ok "complete append"
    |> fsynced "complete append"
  in
  let settled = ok "settle append" (P.settle ~now:12.0 ~base_path ~partition:completed) in
  Alcotest.(check int)
    "one row per state transition"
    5
    (List.length (ledger_lines ledger_path));
  let settled_bytes = Fs_compat.load_file ledger_path in
  ignore (ok "idempotent settlement" (P.settle ~now:13.0 ~base_path ~partition:settled) : P.t);
  Alcotest.(check string)
    "idempotent settlement appends nothing"
    settled_bytes
    (Fs_compat.load_file ledger_path);
  Alcotest.(check int)
    "settled history recovers no execution"
    0
    (ok
       "startup compaction"
       (P.recover_for_process_start ~now:20.0 ~base_path ~keeper_name:"sangsu"));
  Alcotest.(check int)
    "startup compacts to one latest row"
    1
    (List.length (ledger_lines ledger_path));
  match ok "load compacted ledger" (P.load ~base_path ~keeper_name:"sangsu") with
  | [ { P.state = P.Settled _; _ } ] -> ()
  | _ -> Alcotest.fail "startup compaction lost the Settled receipt"
;;

let test_restart_releases_only_unbound_and_quarantines_dispatchable () =
  with_temp_base "board-attention-partition-restart-hard-cut" @@ fun base_path ->
  let unbound_candidate = candidate ~id:"candidate-unbound" ~recorded_at:1.0 () in
  let bound_candidate = candidate ~id:"candidate-bound" ~recorded_at:2.0 () in
  let advancing_candidate = candidate ~id:"candidate-advancing" ~recorded_at:3.0 () in
  ignore
    (roots ~base_path [ advancing_candidate; bound_candidate; unbound_candidate ] : P.t list);
  let owner = P.Worker_epoch.generate () in
  let unbound = claim ~base_path ~worker_epoch:owner ~now:10.0 in
  let bound_claim = claim ~base_path ~worker_epoch:owner ~now:11.0 in
  let bound_proof = provenance ~slot_id:"bound-slot" ~call_id:"bound-call" () in
  ignore
    (P.bind_before_dispatch
       ~worker_epoch:owner
       ~base_path
       ~partition:bound_claim
       ~provenance:bound_proof
     |> ok "bind restart fixture"
     |> fsynced "bind restart fixture"
      : P.t);
  let advancing_claim = claim ~base_path ~worker_epoch:owner ~now:12.0 in
  let failed = provenance ~slot_id:"failed-slot" ~call_id:"failed-call" () in
  let next = provenance ~slot_id:"next-slot" ~call_id:"next-call" () in
  let advancing_bound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:advancing_claim
      ~provenance:failed
    |> ok "bind advancing fixture"
    |> fsynced "bind advancing fixture"
  in
  ignore
    (P.record_before_advance
       ~worker_epoch:owner
       ~base_path
       ~partition:advancing_bound
       ~failed
       ~next
     |> ok "advance restart fixture"
     |> fsynced "advance restart fixture"
      : P.t);
  Alcotest.(check int)
    "all prior Running roots are explicitly resolved"
    3
    (ok
       "process-start recovery"
       (P.recover_for_process_start ~now:20.0 ~base_path ~keeper_name:"sangsu"));
  let recovered = ok "load recovered partitions" (P.load ~base_path ~keeper_name:"sangsu") in
  (match recovered with
   | [ first; second; third ] ->
     (match first.state with
      | P.Ready ->
        Alcotest.(check string)
          "only Unbound returns Ready"
          unbound.candidate_id
          first.candidate_id
      | _ -> Alcotest.fail "Unbound Running did not return Ready");
     (match second.state with
      | P.Blocked
          { reason = P.Exact_execution_quarantined (P.Bound durable); _ } ->
        Alcotest.(check bool) "Bound proof retained in quarantine" true (durable = bound_proof)
      | _ -> Alcotest.fail "Bound Running was not quarantined");
     (match third.state with
      | P.Blocked
          { reason = P.Exact_execution_quarantined (P.Advancing durable); _ } ->
        Alcotest.(check bool) "failed proof retained in quarantine" true (durable.failed = failed);
        Alcotest.(check bool) "next proof retained in quarantine" true (durable.next = next)
      | _ -> Alcotest.fail "Advancing Running was not quarantined");
     let settled_blocked =
       ok "settle terminal Blocked" (P.settle ~now:21.0 ~base_path ~partition:second)
     in
     (match settled_blocked.state with
      | P.Settled _ -> ()
      | _ -> Alcotest.fail "Blocked did not settle")
   | _ -> Alcotest.fail "restart changed partition membership");
  let reclaimed = claim ~base_path ~worker_epoch:owner ~now:22.0 in
  Alcotest.(check string)
    "only prior Unbound can be reclaimed"
    unbound_candidate.candidate_id
    reclaimed.candidate_id;
  Alcotest.(check (option string))
    "quarantined executions are never redispatched"
    None
    (ok
       "no second claim"
       (P.claim_next
          ~now:23.0
          ~worker_epoch:owner
          ~base_path
          ~keeper_name:"sangsu")
     |> Option.map (fun partition -> partition.P.candidate_id))
;;

let test_provider_neutral_blocked_reason_codec () =
  let reasons : (string * P.blocked_reason) list =
    [ "setup", P.Exact_setup_unavailable "lane admission unavailable"
    ; "replay", P.Exact_flow_replayed
    ; "terminal", P.Exact_execution_terminal
    ; "domain", P.Domain_output_invalid "judgment schema rejected"
    ; "provenance", P.Execution_provenance_mismatch "opaque identity mismatch"
    ; "worker", P.Unexpected_worker_failure "worker terminated unexpectedly"
    ]
  in
  List.iteri
    (fun index (label, reason) ->
       with_temp_base ("board-attention-partition-blocked-" ^ label) @@ fun base_path ->
       let pending =
         candidate
           ~id:(Printf.sprintf "candidate-blocked-%d" index)
           ~recorded_at:(float_of_int (index + 1))
           ()
       in
       ignore (roots ~base_path [ pending ] : P.t list);
       let owner = P.Worker_epoch.generate () in
       let claimed = claim ~base_path ~worker_epoch:owner ~now:10.0 in
       let blocked =
         ok
           ("block " ^ label)
           (P.block ~now:11.0 ~worker_epoch:owner ~base_path ~partition:claimed reason)
         |> fsynced ("block " ^ label)
       in
       (match blocked.state with
        | P.Blocked { reason = durable; _ } ->
          Alcotest.(check bool) (label ^ " reason persisted exactly") true (durable = reason)
        | _ -> Alcotest.failf "%s reason did not produce Blocked" label);
       Alcotest.(check bool)
         (label ^ " current-schema roundtrip")
         true
         (ok (label ^ " decode") (P.of_yojson (P.to_yojson blocked)) = blocked))
    reasons;
  with_temp_base "board-attention-partition-blocked-invalid" @@ fun base_path ->
  let pending = candidate ~id:"candidate-empty-reason" ~recorded_at:1.0 () in
  ignore (roots ~base_path [ pending ] : P.t list);
  let owner = P.Worker_epoch.generate () in
  let claimed = claim ~base_path ~worker_epoch:owner ~now:10.0 in
  expect_error
    "empty provider-neutral detail"
    (P.block
       ~now:11.0
       ~worker_epoch:owner
       ~base_path
       ~partition:claimed
       (P.Exact_setup_unavailable ""));
  match ok "load after rejected reason" (P.load ~base_path ~keeper_name:"sangsu") with
  | [ { P.state = P.Running { progress = P.Unbound; _ }; _ } ] -> ()
  | _ -> Alcotest.fail "invalid blocked reason mutated the partition"
;;

let replace_field key value = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (existing, current) ->
            if String.equal existing key then existing, value else existing, current)
         fields)
  | _ -> Alcotest.fail "partition row was not an object"
;;

let test_strict_current_schema_rejects_old_json () =
  with_temp_base "board-attention-partition-codec" @@ fun base_path ->
  let created =
    match roots ~base_path [ candidate ~id:"candidate-codec" ~recorded_at:1.0 () ] with
    | [ partition ] -> partition
    | _ -> Alcotest.fail "expected one partition"
  in
  let encoded = P.to_yojson created in
  Alcotest.(check bool)
    "strict codec roundtrip"
    true
    (ok "decode" (P.of_yojson encoded) = created);
  expect_error
    "old schema is rejected without migration"
    (P.of_yojson (replace_field "schema_version" (`Int 3) encoded));
  let old_running =
    `Assoc
      [ "kind", `String "running"
      ; "worker_epoch", `String (P.Worker_epoch.generate () |> P.Worker_epoch.to_string)
      ; "started_at", `Float 2.0
      ]
  in
  expect_error
    "old Running shape is rejected"
    (P.of_yojson (replace_field "state" old_running encoded));
  let retired_blocked =
    `Assoc
      [ "kind", `String "blocked"
      ; "reason", `Assoc [ "kind", `String "judgment_blocked" ]
      ; "blocked_at", `Float 3.0
      ]
  in
  expect_error
    "retired judgment failure JSON is rejected"
    (P.of_yojson (replace_field "state" retired_blocked encoded));
  let malformed = replace_field "partition_id" (`String "forged-root") encoded in
  let ledger_path = P.For_testing.path ~base_path ~keeper_name:"sangsu" in
  ok
    "inject malformed durable row"
    (Fs_compat.save_file_atomic ledger_path (Yojson.Safe.to_string malformed ^ "\n"));
  expect_error "forged deterministic root identity" (P.load ~base_path ~keeper_name:"sangsu")
;;

let inject_torn_tail ledger_path =
  let output = open_out_gen [ Open_wronly; Open_append; Open_binary ] 0o600 ledger_path in
  output_string output "{\"schema_version\":4,\"partition_id\":\"torn-partial";
  close_out output
;;

let test_torn_tail_recovery_preserves_current_hard_cut () =
  with_temp_base "board-attention-partition-torn-tail" @@ fun base_path ->
  let pending = candidate ~id:"candidate-torn" ~recorded_at:1.0 () in
  ignore (roots ~base_path [ pending ] : P.t list);
  let ledger_path = P.For_testing.path ~base_path ~keeper_name:"sangsu" in
  let durable = Fs_compat.load_file ledger_path in
  inject_torn_tail ledger_path;
  expect_error
    "torn tail still hard-fails general reads"
    (P.load ~base_path ~keeper_name:"sangsu");
  Alcotest.(check int)
    "torn tail without Running recovers nothing"
    0
    (ok
       "torn-tail process-start recovery"
       (P.recover_for_process_start ~now:10.0 ~base_path ~keeper_name:"sangsu"));
  Alcotest.(check string)
    "torn tail truncated to last complete row"
    durable
    (Fs_compat.load_file ledger_path);
  let owner = P.Worker_epoch.generate () in
  ignore (claim ~base_path ~worker_epoch:owner ~now:11.0 : P.t);
  inject_torn_tail ledger_path;
  Alcotest.(check int)
    "only Unbound Running is released"
    1
    (ok
       "torn Unbound recovery"
       (P.recover_for_process_start ~now:12.0 ~base_path ~keeper_name:"sangsu"));
  match ok "load after torn recovery" (P.load ~base_path ~keeper_name:"sangsu") with
  | [ { P.state = P.Ready; candidate_id; _ } ] ->
    Alcotest.(check string) "candidate remains recoverable" pending.candidate_id candidate_id
  | _ -> Alcotest.fail "torn-tail recovery lost the current partition"
;;

let test_invalid_or_mismatched_provenance_never_rewrites () =
  with_temp_base "board-attention-partition-invalid" @@ fun base_path ->
  expect_error
    "non-finite candidate time"
    (P.ensure_roots
       ~base_path
       ~keeper_name:"sangsu"
       [ candidate ~id:"candidate-invalid" ~recorded_at:Float.nan () ]);
  let valid = candidate ~id:"candidate-valid" ~recorded_at:1.0 () in
  ignore (roots ~base_path [ valid ] : P.t list);
  let owner = P.Worker_epoch.generate () in
  let claimed = claim ~base_path ~worker_epoch:owner ~now:2.0 in
  expect_error
    "empty opaque provenance"
    (P.bind_before_dispatch
       ~worker_epoch:owner
       ~base_path
       ~partition:claimed
       ~provenance:(provenance ~plan_fingerprint:"" ()));
  let proof = provenance () in
  let bound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:claimed
      ~provenance:proof
    |> ok "bind valid proof"
    |> fsynced "bind valid proof"
  in
  let invalid_item : P.completed_item =
    { candidate_id = valid.candidate_id
    ; judgment = judgment ~judged_at:Float.infinity proof
    }
  in
  expect_error
    "non-finite judgment time"
    (P.complete ~now:3.0 ~worker_epoch:owner ~base_path ~partition:bound ~item:invalid_item);
  expect_error
    "mismatched judgment provenance"
    (P.complete
       ~now:3.0
       ~worker_epoch:owner
       ~base_path
       ~partition:bound
       ~item:
         { candidate_id = valid.candidate_id
         ; judgment = judgment (provenance ~request_body_sha256:"other-body" ())
         });
  match ok "load Bound after rejected completion" (P.load ~base_path ~keeper_name:"sangsu") with
  | [ { P.state = P.Running { progress = P.Bound durable; _ }; _ } ] ->
    Alcotest.(check bool) "durable binding remains intact" true (durable = proof)
  | _ -> Alcotest.fail "rejected completion mutated the durable binding"
;;

let () =
  Alcotest.run
    "keeper_board_attention_partition"
    [ ( "durable singleton exact FSM"
      , [ Alcotest.test_case
            "roots are deterministic singleton context partitions"
            `Quick
            test_roots_are_singleton_deterministic_and_context_exact
        ; Alcotest.test_case
            "binding owns completion and settlement"
            `Quick
            test_binding_owns_completion_and_settlement
        ; Alcotest.test_case
            "existing judgment completion is atomic and restart safe"
            `Quick
            test_existing_judgment_completion_is_atomic_and_restart_safe
        ; Alcotest.test_case
            "before advance is atomic and exact"
            `Quick
            test_before_advance_is_atomic_and_exact
        ; Alcotest.test_case
            "runtime transitions append then startup compacts"
            `Quick
            test_runtime_transitions_append_then_startup_compacts
        ; Alcotest.test_case
            "restart releases only Unbound and quarantines dispatchable"
            `Quick
            test_restart_releases_only_unbound_and_quarantines_dispatchable
        ; Alcotest.test_case
            "provider-neutral blocked reasons roundtrip"
            `Quick
            test_provider_neutral_blocked_reason_codec
        ; Alcotest.test_case
            "strict current schema rejects old JSON"
            `Quick
            test_strict_current_schema_rejects_old_json
        ; Alcotest.test_case
            "torn tail recovery preserves current hard cut"
            `Quick
            test_torn_tail_recovery_preserves_current_hard_cut
        ; Alcotest.test_case
            "invalid or mismatched provenance never rewrites"
            `Quick
            test_invalid_or_mismatched_provenance_never_rewrites
        ] )
    ]
;;
