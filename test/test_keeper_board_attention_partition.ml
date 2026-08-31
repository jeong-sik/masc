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

let candidate ?(keeper_name = "alpha") ?(context = context "primary") ~id ~recorded_at () :
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

let candidate_visit
      ?(flow_id = "flow-1")
      ?(ordinal = 1)
      ?(slot_id = "slot-next")
      ?(catalog_generation_fingerprint = "generation-1")
      ?(catalog_evidence_sha256 = "evidence-1")
      ?(target_identity_fingerprint = "target-1")
      ()
  : P.candidate_visit
  =
  { flow_id
  ; ordinal
  ; slot_id
  ; catalog_generation_fingerprint
  ; catalog_evidence_sha256
  ; target_identity_fingerprint
  }
;;

let judgment ?(judged_at = 101.0) (proof : P.exact_provenance) : A.judgment =
  { verdict = { J.decision = J.Relevant; rationale = "react to this Board event" }
  ; slot_id = proof.slot_id
  ; source =
      A.Exact_attempt
        { call_id = proof.call_id
        ; plan_fingerprint = proof.plan_fingerprint
        ; request_body_sha256 = proof.request_body_sha256
        }
  ; judged_at
  }
;;

let roots ~base_path candidates =
  ignore
    (ok "ensure roots" (P.ensure_roots ~base_path ~keeper_name:"alpha" candidates) : int);
  ok "load roots" (P.load ~base_path ~keeper_name:"alpha")
;;

let claim ~base_path ~worker_epoch ~now =
  let target =
    ok "load claim target" (P.load ~base_path ~keeper_name:"alpha")
    |> List.find_opt (fun (partition : P.t) ->
      match partition.state with
      | P.Ready -> true
      | P.Running _ | P.Completed _ | P.Settled _ | P.Blocked _ -> false)
  in
  let target =
    match target with
    | Some target -> target
    | None -> Alcotest.fail "expected a Ready partition"
  in
  match
    ok
      "claim exact Ready target"
      (P.claim_ready_exact
         ~now
         ~worker_epoch
         ~base_path
         ~keeper_name:"alpha"
         ~partition_id:target.partition_id
         ~generation:target.generation)
  with
  | Some partition -> partition
  | None -> Alcotest.fail "exact Ready target lost its claim"
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
          ~keeper_name:"alpha"
          [ first; second; isolated ]));
  let repeated = ok "load repeated roots" (P.load ~base_path ~keeper_name:"alpha") in
  Alcotest.(check bool) "root creation is idempotent" true (created = repeated);
  expect_error
    "same candidate identity with changed context"
    (P.ensure_roots
       ~base_path
       ~keeper_name:"alpha"
       [ { first with judgment_request = `Assoc [ "keeper_context", context "changed" ] } ]);
  let primary_key = (List.hd created).P.context_key in
  let isolated_key = (List.hd (List.rev created)).P.context_key in
  Alcotest.(check bool)
    "different exact Keeper contexts do not collapse"
    false
    (A.Context_key.equal primary_key isolated_key)
;;

let test_exact_claim_never_claims_a_ready_sibling () =
  with_temp_base "board-attention-partition-exact-claim" @@ fun base_path ->
  let first = candidate ~id:"candidate-first" ~recorded_at:1.0 () in
  let second = candidate ~id:"candidate-second" ~recorded_at:2.0 () in
  let partitions = roots ~base_path [ first; second ] in
  let partition_for candidate =
    match
      List.find_opt
        (fun (partition : P.t) ->
           String.equal partition.candidate_id candidate.A.candidate_id)
        partitions
    with
    | Some partition -> partition
    | None -> Alcotest.fail "candidate root is absent"
  in
  let first_partition = partition_for first in
  let second_partition = partition_for second in
  let competitor = P.Worker_epoch.generate () in
  ignore
    (ok
       "competitor claims selected target"
       (P.claim_ready_exact
          ~now:10.0
          ~worker_epoch:competitor
          ~base_path
          ~keeper_name:"alpha"
          ~partition_id:first_partition.partition_id
          ~generation:first_partition.generation)
     : P.t option);
  let stale_worker = P.Worker_epoch.generate () in
  Alcotest.(check bool)
    "stale target does not redirect to a sibling"
    true
    (Option.is_none
       (ok
          "stale exact target claim"
          (P.claim_ready_exact
             ~now:11.0
             ~worker_epoch:stale_worker
             ~base_path
             ~keeper_name:"alpha"
             ~partition_id:first_partition.partition_id
             ~generation:first_partition.generation)));
  (match
     ok "load after stale target conflict" (P.load ~base_path ~keeper_name:"alpha")
     |> List.find_opt (fun (partition : P.t) ->
       String.equal partition.partition_id second_partition.partition_id)
   with
   | Some { state = P.Ready; _ } -> ()
   | Some _ | None -> Alcotest.fail "stale claim mutated the Ready sibling");
  match
    ok
      "claim explicitly reselected sibling"
      (P.claim_ready_exact
         ~now:12.0
         ~worker_epoch:stale_worker
         ~base_path
         ~keeper_name:"alpha"
         ~partition_id:second_partition.partition_id
         ~generation:second_partition.generation)
  with
  | Some claimed ->
    Alcotest.(check string)
      "explicit target identity"
      second_partition.partition_id
      claimed.partition_id
  | None -> Alcotest.fail "explicitly reselected sibling was not claimed"
;;

let test_generation_advances_only_for_state_transition () =
  with_temp_base "board-attention-partition-generation" @@ fun base_path ->
  let pending = candidate ~id:"candidate-generation" ~recorded_at:1.0 () in
  let ready =
    match roots ~base_path [ pending ] with
    | [ partition ] -> partition
    | _ -> Alcotest.fail "generation fixture did not create one root"
  in
  let owner = P.Worker_epoch.generate () in
  let running =
    match
      ok
        "claim generation fixture"
        (P.claim_ready_exact
           ~now:2.0
           ~worker_epoch:owner
           ~base_path
           ~keeper_name:"alpha"
           ~partition_id:ready.partition_id
           ~generation:ready.generation)
    with
    | Some partition -> partition
    | None -> Alcotest.fail "generation fixture lost its Ready target"
  in
  Alcotest.(check bool)
    "Ready to Running is one successor"
    true
    (P.Generation.is_direct_successor
       ~previous:ready.generation
       running.generation);
  let proof = provenance () in
  let bound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:running
      ~provenance:proof
    |> ok "bind generation fixture"
    |> fsynced "bind generation fixture"
  in
  Alcotest.(check bool)
    "Running progress transition is one successor"
    true
    (P.Generation.is_direct_successor
       ~previous:running.generation
       bound.generation);
  let replay =
    ok
      "reappend unchanged Bound generation"
      (P.bind_before_dispatch
         ~worker_epoch:owner
         ~base_path
         ~partition:bound
         ~provenance:proof)
  in
  Alcotest.(check bool) "unchanged reappend reports no change" false replay.changed;
  Alcotest.(check bool)
    "unchanged reappend retains generation"
    true
    (P.Generation.equal bound.generation replay.partition.generation)
;;

let cli_judgment ?(judged_at = 101.0) ~slot_id () : A.judgment =
  { verdict = { J.decision = J.Relevant; rationale = "react to this Board event" }
  ; slot_id
  ; source = A.Cli_lane_slot
  ; judged_at
  }
;;

(* RFC cli-runtimes-as-lane-slots: the tail answers only after the catalog is
   exhausted, and there is no attempt receipt to match a completion against.
   What stands in for it is the binding the exhausted flow left behind, so an
   Unbound partition must still refuse -- otherwise a lane could reach the tail
   without ever dispatching its own slots. *)
let test_cli_slot_completion_requires_an_exhausted_binding () =
  with_temp_base "board-attention-partition-cli-tail" @@ fun base_path ->
  let pending = candidate ~id:"candidate-cli-tail" ~recorded_at:1.0 () in
  ignore (roots ~base_path [ pending ] : P.t list);
  let owner = P.Worker_epoch.generate () in
  let claimed = claim ~base_path ~worker_epoch:owner ~now:10.0 in
  let item : P.completed_item =
    { candidate_id = claimed.candidate_id
    ; judgment = cli_judgment ~slot_id:"claude_code.claude-sonnet-5" ()
    }
  in
  expect_error
    "cli completion without a durable exact binding"
    (P.complete ~now:11.0 ~worker_epoch:owner ~base_path ~partition:claimed ~item);
  let bound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:claimed
      ~provenance:(provenance ())
    |> ok "bind before dispatch"
    |> fsynced "bind before dispatch"
  in
  let completed =
    P.complete ~now:12.0 ~worker_epoch:owner ~base_path ~partition:bound ~item
    |> ok "cli completion after exhaustion"
    |> fsynced "cli completion after exhaustion"
  in
  match completed.state with
  | P.Completed { item = persisted; _ } ->
    Alcotest.(check string)
      "the answering client is the persisted slot"
      "claude_code.claude-sonnet-5"
      persisted.judgment.slot_id;
    (match persisted.judgment.source with
     | A.Cli_lane_slot -> ()
     | A.Exact_attempt _ ->
       Alcotest.fail "a cli completion must not be recorded as an exact attempt")
  | _ -> Alcotest.fail "cli completion did not reach Completed"
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
    (ok "load projected judgment" (P.load ~base_path ~keeper_name:"alpha"));
  Alcotest.(check int)
    "restart does not recover completed existing judgment"
    0
    (ok
       "restart after existing judgment completion"
       (P.recover_for_process_start ~now:12.0 ~base_path ~keeper_name:"alpha"));
  require_projected
    "restart"
    (ok "load after restart" (P.load ~base_path ~keeper_name:"alpha"));
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
  let released_claim = claim ~base_path ~worker_epoch:owner ~now:15.0 in
  let failed =
    provenance ~slot_id:"failed-existing-slot" ~call_id:"failed-existing-call" ()
  in
  let released_bound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:released_claim
      ~provenance:failed
    |> ok "bind released existing-judgment rejection fixture"
    |> fsynced "bind released existing-judgment rejection fixture"
  in
  let next = candidate_visit ~slot_id:"next-existing-slot" () in
  let advancing =
    P.record_before_advance
      ~worker_epoch:owner
      ~base_path
      ~partition:released_bound
      ~source:(P.Executed_failure failed)
      ~next
    |> ok "record existing-judgment advancement fixture"
    |> fsynced "record existing-judgment advancement fixture"
  in
  expect_error
    "existing judgment cannot bypass AGENT_CORE-selected advancement"
    (P.complete_existing_judgment
       ~now:16.0
       ~worker_epoch:owner
       ~base_path
       ~partition:advancing
       ~item:
         { candidate_id = advancing_candidate.candidate_id
         ; judgment = judgment failed
         });
  ignore (completed : P.t)
;;

let test_before_advance_record_is_atomic_and_exact () =
  with_temp_base "board-attention-partition-advance" @@ fun base_path ->
  let pending = candidate ~id:"candidate-advance" ~recorded_at:1.0 () in
  ignore (roots ~base_path [ pending ] : P.t list);
  let owner = P.Worker_epoch.generate () in
  let claimed = claim ~base_path ~worker_epoch:owner ~now:10.0 in
  let failed = provenance ~slot_id:"slot-failed" ~call_id:"call-failed" () in
  let next_visit = candidate_visit ~slot_id:"slot-next" () in
  let next = provenance ~slot_id:next_visit.slot_id ~call_id:"call-next" () in
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
       ~source:
         (P.Executed_failure (provenance ~call_id:"other-call" ()))
       ~next:next_visit);
  let advance_transition =
    ok
      "record before advance"
      (P.record_before_advance
         ~worker_epoch:owner
         ~base_path
         ~partition:bound
         ~source:(P.Executed_failure failed)
         ~next:next_visit)
  in
  Alcotest.(check bool)
    "advance record changes durable state"
    true
    advance_transition.changed;
  let advancing = fsynced "record before advance" advance_transition in
  (match advancing.state with
   | P.Running { progress = P.Advancing durable; _ } ->
     Alcotest.(check bool)
       "failed receipt and selected visit persist exactly"
       true
       (durable.execution_anchor = Some failed
        && durable.last_from = None
        && durable.next = next_visit)
   | _ -> Alcotest.fail "partition did not retain Advancing evidence");
  let rebound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:advancing
      ~provenance:next
    |> ok "bind AGENT_CORE-selected successor"
    |> fsynced "bind AGENT_CORE-selected successor"
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
  let ledger_path = P.For_testing.path ~base_path ~keeper_name:"alpha" in
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
       (P.recover_for_process_start ~now:20.0 ~base_path ~keeper_name:"alpha"));
  Alcotest.(check int)
    "startup compacts to one latest row"
    1
    (List.length (ledger_lines ledger_path));
  match ok "load compacted ledger" (P.load ~base_path ~keeper_name:"alpha") with
  | [ { P.state = P.Settled _; _ } ] -> ()
  | _ -> Alcotest.fail "startup ledger rewrite lost the Settled receipt"
;;

let test_restart_releases_only_unbound_and_quarantines_dispatchable () =
  with_temp_base "board-attention-partition-restart-hard-cut" @@ fun base_path ->
  let unbound_candidate = candidate ~id:"candidate-unbound" ~recorded_at:1.0 () in
  let bound_candidate = candidate ~id:"candidate-bound" ~recorded_at:2.0 () in
  ignore
    (roots ~base_path [ bound_candidate; unbound_candidate ] : P.t list);
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
  Alcotest.(check int)
    "all prior Running roots are explicitly resolved"
    2
    (ok
       "process-start recovery"
       (P.recover_for_process_start ~now:20.0 ~base_path ~keeper_name:"alpha"));
  let recovered = ok "load recovered partitions" (P.load ~base_path ~keeper_name:"alpha") in
  (match recovered with
   | [ first; second ] ->
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
  Alcotest.(check (list string))
    "quarantined executions are never redispatched"
    []
    (ok "load terminalized roots" (P.load ~base_path ~keeper_name:"alpha")
     |> List.filter_map (fun (partition : P.t) ->
       match partition.state with
       | P.Ready -> Some partition.candidate_id
       | P.Running _ | P.Completed _ | P.Settled _ | P.Blocked _ -> None))
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
  match ok "load after rejected reason" (P.load ~base_path ~keeper_name:"alpha") with
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
    "immediate prior schema v5 is rejected without migration"
    (P.of_yojson (replace_field "schema_version" (`Int 5) encoded));
  expect_error
    "old schema is rejected without migration"
    (P.of_yojson (replace_field "schema_version" (`Int 4) encoded));
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
  let ledger_path = P.For_testing.path ~base_path ~keeper_name:"alpha" in
  ok
    "inject malformed durable row"
    (Fs_compat.save_file_atomic ledger_path (Yojson.Safe.to_string malformed ^ "\n"));
  expect_error "forged deterministic root identity" (P.load ~base_path ~keeper_name:"alpha")
;;

let inject_torn_tail ledger_path =
  let output = open_out_gen [ Open_wronly; Open_append; Open_binary ] 0o600 ledger_path in
  output_string output "{\"schema_version\":6,\"partition_id\":\"torn-partial";
  close_out output
;;

let test_torn_tail_recovery_preserves_current_hard_cut () =
  with_temp_base "board-attention-partition-torn-tail" @@ fun base_path ->
  let pending = candidate ~id:"candidate-torn" ~recorded_at:1.0 () in
  ignore (roots ~base_path [ pending ] : P.t list);
  let ledger_path = P.For_testing.path ~base_path ~keeper_name:"alpha" in
  let durable = Fs_compat.load_file ledger_path in
  inject_torn_tail ledger_path;
  expect_error
    "torn tail still hard-fails general reads"
    (P.load ~base_path ~keeper_name:"alpha");
  Alcotest.(check int)
    "torn tail without Running recovers nothing"
    0
    (ok
       "torn-tail process-start recovery"
       (P.recover_for_process_start ~now:10.0 ~base_path ~keeper_name:"alpha"));
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
       (P.recover_for_process_start ~now:12.0 ~base_path ~keeper_name:"alpha"));
  match ok "load after torn recovery" (P.load ~base_path ~keeper_name:"alpha") with
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
       ~keeper_name:"alpha"
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
  match ok "load Bound after rejected completion" (P.load ~base_path ~keeper_name:"alpha") with
  | [ { P.state = P.Running { progress = P.Bound durable; _ }; _ } ] ->
    Alcotest.(check bool) "durable binding remains intact" true (durable = proof)
  | _ -> Alcotest.fail "rejected completion mutated the durable binding"
;;

let test_predispatch_rejection_chain_binds_agent_core_selected_third_slot () =
  with_temp_base "board-attention-partition-predispatch-chain" @@ fun base_path ->
  let pending = candidate ~id:"candidate-predispatch-chain" ~recorded_at:1.0 () in
  ignore (roots ~base_path [ pending ] : P.t list);
  let owner = P.Worker_epoch.generate () in
  let claimed = claim ~base_path ~worker_epoch:owner ~now:10.0 in
  let first = candidate_visit ~slot_id:"slot-a" () in
  let second =
    { (candidate_visit ~slot_id:"slot-b" ()) with ordinal = first.ordinal + 1 }
  in
  let third =
    { (candidate_visit ~slot_id:"slot-c" ()) with ordinal = second.ordinal + 1 }
  in
  let after_first =
    P.record_before_advance
      ~worker_epoch:owner
      ~base_path
      ~partition:claimed
      ~source:(P.Predispatch_rejection first)
      ~next:second
    |> ok "record first predispatch rejection"
    |> fsynced "record first predispatch rejection"
  in
  let after_second =
    P.record_before_advance
      ~worker_epoch:owner
      ~base_path
      ~partition:after_first
      ~source:(P.Predispatch_rejection second)
      ~next:third
    |> ok "record second predispatch rejection"
    |> fsynced "record second predispatch rejection"
  in
  (match after_second.state with
   | P.Running
       { progress =
           P.Advancing
             { execution_anchor = None
             ; last_from = Some durable
             ; next = durable_next
             }
       ; _
       } ->
     Alcotest.(check bool)
       "latest rejected visit and AGENT_CORE successor are durable"
       true
       (durable = second && durable_next = third)
   | _ -> Alcotest.fail "predispatch chain did not retain latest advancement");
  let third_provenance = provenance ~slot_id:third.slot_id ~call_id:"call-c" () in
  let rebound =
    P.bind_before_dispatch
      ~worker_epoch:owner
      ~base_path
      ~partition:after_second
      ~provenance:third_provenance
    |> ok "bind AGENT_CORE-selected third slot"
    |> fsynced "bind AGENT_CORE-selected third slot"
  in
  match rebound.state with
  | P.Running { progress = P.Bound durable; _ } ->
    Alcotest.(check bool)
      "third slot exact provenance is bound"
      true
      (durable = third_provenance)
  | _ -> Alcotest.fail "third AGENT_CORE-selected slot was not bindable"
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
            "exact claim never redirects to a Ready sibling"
            `Quick
            test_exact_claim_never_claims_a_ready_sibling
        ; Alcotest.test_case
            "generation advances only for state transitions"
            `Quick
            test_generation_advances_only_for_state_transition
        ; Alcotest.test_case
            "binding owns completion and settlement"
            `Quick
            test_binding_owns_completion_and_settlement
        ; Alcotest.test_case
            "a cli-slot completion requires an exhausted exact binding"
            `Quick
            test_cli_slot_completion_requires_an_exhausted_binding
        ; Alcotest.test_case
            "existing judgment completion is atomic and restart safe"
            `Quick
            test_existing_judgment_completion_is_atomic_and_restart_safe
        ; Alcotest.test_case
            "before advance record is atomic and exact"
            `Quick
            test_before_advance_record_is_atomic_and_exact
        ; Alcotest.test_case
            "predispatch rejection chain binds AGENT_CORE-selected third slot"
            `Quick
            test_predispatch_rejection_chain_binds_agent_core_selected_third_slot
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
