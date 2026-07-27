(** MASC-owned composition proof for the compaction OAS exact-flow boundary.

    OAS owns admission, affine attempts, execute-once, advancement, and receipt
    semantics. These tests observe only MASC-owned ordered opaque slot identity,
    durable bind/release/quarantine callbacks, domain validation, registry
    generation, and source terminalization. *)

(* #25969 removed [Keeper_heartbeat_loop.For_testing.exact_execution_guard],
   the only constructor for a durable exact-execution guard, and no producer
   replaced it: [quarantine_exact_execution] now always returns
   "exact execution guard is unavailable". Seven cases that drove a real
   persistence-backed guard were removed here rather than rewritten against
   the permissive stub, which cannot observe durability at all. What they
   covered is recorded in the commit message and in #25981.

   Removed: same_flow_concurrent_loser_mutates_no_queue,
   heartbeat_guard_binds_before_post,
   post_success_restart_remains_at_most_once_and_fail_closed,
   post_success_terminalization_is_canonical_and_durable,
   post_success_terminalization_overlap_is_affine_and_durable,
   post_success_terminalization_failures_preserve_full_binding,
   visible_sync_uncertainty_seams. *)

open Masc

module C = Keeper_compaction_llm_summarizer
module F = Compaction_exact_output_fixture
module P = Keeper_event_queue_persistence
module Recovery = Keeper_exact_disposition_recovery
module Registry = Runtime_exact_output_registry
module S = Keeper_structured_output_schema
module State = Keeper_event_queue_state
module T = Agent_sdk.Types
module U = Keeper_compaction_unit

exception Cancel_after_request_arrived
exception Stop_after_oas_success of C.attempt_observation

let conformance_lane_id = "compaction-exact-conformance"

let run_eio f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  f
    ~sw
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

(* claim_manual_lease, persisted_checkpoint_source_exn, and
   settle_terminal_disposition_result used to live here. They existed only to
   drive the durable exact-execution guard removed above (a claimed lease to
   bind it to, a checkpoint source and a terminal disposition to settle
   against), so none of the surviving cases call them. *)

let execute_prepared_lane
      ~keeper_name
      ~net
      ?clock
      ?(exact_execution_guard = F.permissive_exact_execution_guard)
      prepared_lane
  =
  C.execute_prepared_lane
    ~keeper_name
    ~net
    ?clock
    ~exact_execution_guard
    prepared_lane
;;

let message role text : T.message =
  { role
  ; content = [ T.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let units =
  [ U.Ordinary_message (message T.Assistant "first source message")
  ; U.Ordinary_message (message T.Assistant "second source message")
  ]
;;

let decision ?summary unit_index action : Yojson.Safe.t =
  `Assoc
    [ S.compaction_plan_field_unit_index, `Int unit_index
    ; S.compaction_plan_field_action, `String action
    ; ( S.compaction_plan_field_summary
      , Option.fold ~none:`Null ~some:(fun value -> `String value) summary )
    ]
;;

let plan_json decisions : Yojson.Safe.t =
  `Assoc [ S.compaction_plan_field_decisions, `List decisions ]
;;

let valid_plan_json =
  plan_json
    [ decision ~summary:"first summary" 0 S.compaction_plan_action_summarize
    ; decision 1 S.compaction_plan_action_keep
    ]
;;

let domain_invalid_plan_json =
  plan_json
    [ decision 0 S.compaction_plan_action_keep
    ; decision 1 S.compaction_plan_action_keep
    ]
;;

let valid_response = F.openai_response valid_plan_json
let domain_invalid_response = F.openai_response domain_invalid_plan_json

let publish_exn ~slot_ids snapshot =
  F.publish_registry ~lane_id:conformance_lane_id ~slot_ids snapshot
;;

let exact_flow_base_path = "/tmp/masc-compaction-exact-output-conformance"

let ensure_registered_keeper ~base_path keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some _ -> ()
  | None ->
    let meta =
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String keeper_name
          ; "trace_id", `String ("trace-" ^ keeper_name)
          ])
      |> Result.get_ok
    in
    ignore (Keeper_registry.register_offline ~base_path keeper_name meta)
;;

let prepare_exn
      ?(base_path = exact_flow_base_path)
      ~keeper_name
      ~registry
      ()
  =
  ensure_registered_keeper ~base_path keeper_name;
  match
    C.prepare_lane
      ~base_path
      ~keeper_name
      ~registry
      ~lane_id:conformance_lane_id
      ~units
  with
  | Ok prepared -> prepared
  | Error _ -> Alcotest.fail "compaction flow preparation failed"
;;

let completed_exn = function
  | Ok completed -> completed
  | Error _ -> Alcotest.fail "compaction flow execution failed"
;;

let terminalized_exn = function
  | C.Terminalized terminal -> terminal
  | C.Terminalization_commit_in_progress _ ->
    Alcotest.fail "terminalization unexpectedly lost to a commit claimant"
  | C.Terminalization_already_committed ->
    Alcotest.fail "terminalization unexpectedly observed a committed checkpoint"
  | C.Terminalization_persistence_failed (_, detail) ->
    Alcotest.failf "terminalization persistence failed: %s" detail
  | C.Terminalization_invariant_failed detail ->
    Alcotest.failf "terminalization invariant failed: %s" detail
;;

let captured_observation_exn label = function
  | Some observation -> observation
  | None -> Alcotest.failf "%s did not observe an OAS attempt identity" label
;;

let check_identity label (observation : C.attempt_observation) =
  Alcotest.(check bool)
    (label ^ " call id")
    true
    (String.trim observation.call_id <> "");
  Alcotest.(check bool)
    (label ^ " catalog generation")
    true
    (String.trim observation.catalog_generation_fingerprint <> "");
  Alcotest.(check bool)
    (label ^ " plan identity")
    true
    (String.trim observation.receipt_plan_fingerprint <> "");
  Alcotest.(check bool)
    (label ^ " request identity")
    true
    (String.trim observation.receipt_request_body_sha256 <> "")
;;

let push_event events event = events := !events @ [ event ]

let test_missing_compaction_lane_is_explicit_degraded_state () =
  let snapshot =
    F.resolver_snapshot
      ~source:"masc missing compaction lane"
      [ { id = "configured-slot"; base_url = "http://127.0.0.1:9" } ]
  in
  let registry =
    match Registry.publish ~lanes:[] snapshot with
    | Ok registry -> registry
    | Error error ->
      Alcotest.failf
        "empty exact-output registry must publish: %s"
        (Registry.publication_error_to_string error)
  in
  let keeper_name = "keeper-missing-compaction-lane" in
  ensure_registered_keeper ~base_path:exact_flow_base_path keeper_name;
  List.iter
    (fun (base_path, requested_keeper) ->
       match
         C.prepare_lane
           ~base_path
           ~keeper_name:requested_keeper
           ~registry
           ~lane_id:"compaction_exact"
           ~units
       with
       | Error C.Exact_execution_context_unavailable -> ()
       | Error _ ->
         Alcotest.fail "wrong registry owner returned the wrong typed failure"
       | Ok _ ->
         Alcotest.fail "wrong registry root/name acquired an exact-flow owner")
    [ exact_flow_base_path ^ "-wrong", keeper_name
    ; exact_flow_base_path, keeper_name ^ "-wrong"
    ];
  match
    C.prepare_lane
      ~base_path:exact_flow_base_path
      ~keeper_name
      ~registry
      ~lane_id:"compaction_exact"
      ~units
  with
  | Error C.Exact_lane_unconfigured -> ()
  | Error _ -> Alcotest.fail "missing lane returned the wrong typed failure"
  | Ok _ -> Alcotest.fail "missing lane must not be synthesized"
;;

let test_preparation_freezes_order_generation_and_defers_attempt_identity () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let first = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let second = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc immutable preparation"
      [ { id = "prepare-first"; base_url = first.base_url }
      ; { id = "prepare-second"; base_url = second.base_url }
      ]
  in
  let registry =
    publish_exn ~slot_ids:[ "prepare-first"; "prepare-second" ] snapshot
  in
  let prepared = prepare_exn ~keeper_name:"keeper-preparation" ~registry () in
  Alcotest.(check (list string))
    "MASC opaque declaration order"
    [ "prepare-first"; "prepare-second" ]
    (C.For_testing.flow_slot_ids prepared);
  Alcotest.(check int64)
    "one immutable MASC registry generation"
    (Registry.generation registry)
    (C.For_testing.registry_generation prepared);
  Alcotest.(check (list string))
    "OAS freezes the effective candidate snapshot"
    [ "prepare-first"; "prepare-second" ]
    (C.For_testing.candidate_snapshot_slot_ids prepared);
  Alcotest.(check int)
    "preparation allocates no candidate attempt"
    0
    (List.length (C.For_testing.attempt_observations prepared));
  Alcotest.(check int) "preparation performs no first POST" 0 (F.post_count first);
  Alcotest.(check int) "preparation performs no second POST" 0 (F.post_count second)
;;

let test_published_replacement_cannot_mix_prepared_generation () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let server_a = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let server_b = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot_a =
    F.resolver_snapshot
      ~source:"masc frozen registry A"
      [ { id = "frozen-slot"; base_url = server_a.base_url } ]
  in
  let registry_a = publish_exn ~slot_ids:[ "frozen-slot" ] snapshot_a in
  let prepared_a = prepare_exn ~keeper_name:"keeper-frozen-a" ~registry:registry_a () in
  let snapshot_b =
    F.resolver_snapshot
      ~source:"masc replacement registry B"
      [ { id = "replacement-slot"; base_url = server_b.base_url } ]
  in
  let registry_b = publish_exn ~slot_ids:[ "replacement-slot" ] snapshot_b in
  Alcotest.(check bool)
    "MASC publication generation advances"
    true
    (Int64.compare (Registry.generation registry_a) (Registry.generation registry_b) < 0);
  let completed =
    execute_prepared_lane
      ~keeper_name:"keeper-frozen-a"
      ~net
      ~clock
      prepared_a
    |> completed_exn
  in
  let evidence = C.completed_exact_execution_evidence completed in
  Alcotest.(check string)
    "execution retains prepared resolver generation"
    (F.catalog_generation_fingerprint snapshot_a)
    (C.exact_execution_evidence_catalog_generation_fingerprint evidence);
  Alcotest.(check int) "prepared A dispatches to A" 1 (F.post_count server_a);
  Alcotest.(check int) "later publication B is not observed" 0 (F.post_count server_b)
;;

let test_durable_release_precedes_successor_bind_and_post () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let events = ref [] in
  let second =
    F.start_server
      ~on_request_before_reply:(fun () -> push_event events "post:second")
      ~sw
      ~net
      ~clock
      (F.Reply valid_response)
  in
  let third = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc OAS advancement order"
      [ { id = "unreachable-first"; base_url = "http://127.0.0.1:9" }
      ; { id = "successful-second"; base_url = second.base_url }
      ; { id = "forbidden-third"; base_url = third.base_url }
      ]
  in
  let registry =
    publish_exn
      ~slot_ids:[ "unreachable-first"; "successful-second"; "forbidden-third" ]
      snapshot
  in
  let prepared = prepare_exn ~keeper_name:"keeper-advance-order" ~registry () in
  let guard : C.exact_execution_guard =
    { before_dispatch =
        (fun observation ->
           push_event events ("bind:" ^ observation.slot_id);
           Ok C.Fsync_completed)
    ; release_before_dispatch =
        (fun observation ->
           push_event events ("release:" ^ observation.slot_id);
           Ok C.Fsync_completed)
    ; quarantine = (fun _ _ -> Alcotest.fail "successful flow must not quarantine")
    }
  in
  ignore
    (execute_prepared_lane
       ~keeper_name:"keeper-advance-order"
       ~net
       ~clock
       ~exact_execution_guard:guard
       prepared
     |> completed_exn
      : C.completed_plan);
  Alcotest.(check (list string))
    "bind A, fsync release A, bind B, then POST B"
    [ "bind:unreachable-first"
    ; "release:unreachable-first"
    ; "bind:successful-second"
    ; "post:second"
    ]
    !events;
  Alcotest.(check int) "successor dispatches once" 1 (F.post_count second);
  Alcotest.(check int) "success prevents another candidate" 0 (F.post_count third)
;;

let test_bind_failure_prevents_post () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc bind failure"
      [ { id = "bind-failure"; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ "bind-failure" ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-bind-failure" ~registry () in
  let guard : C.exact_execution_guard =
    { before_dispatch = (fun _ -> Error "injected durable bind failure")
    ; release_before_dispatch = (fun _ -> Alcotest.fail "release must not run")
    ; quarantine = (fun _ _ -> Alcotest.fail "quarantine must not run")
    }
  in
  (match
     execute_prepared_lane
       ~keeper_name:"keeper-bind-failure"
       ~net
       ~clock
       ~exact_execution_guard:guard
       prepared
   with
   | Error C.Exact_execution_bind_failed -> ()
   | Error _ -> Alcotest.fail "bind failure returned the wrong typed failure"
   | Ok _ -> Alcotest.fail "bind failure unexpectedly executed");
  Alcotest.(check int) "bind failure prevents POST" 0 (F.post_count server)
;;

let test_dispatch_authority_without_queue_guard () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let slot_id = "missing-dispatch-guard" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc missing dispatch guard"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-missing-guard" ~registry () in
  (match
     C.execute_prepared_lane
       ~keeper_name:"keeper-missing-guard"
       ~net
       ~clock
       ~before_dispatch_authority:(fun _ -> Ok ())
       prepared
   with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "keeper-lifecycle execution did not dispatch");
  (match
     C.execute_prepared_lane
       ~keeper_name:"keeper-missing-guard"
       ~net
       ~clock
       prepared
   with
   | Error C.Exact_flow_already_started -> ()
   | Error _ -> Alcotest.fail "consumed lifecycle-owned flow hid affine replay"
   | Ok _ -> Alcotest.fail "consumed missing-guard flow executed twice");
  Alcotest.(check int) "keeper lifecycle permits one POST" 1 (F.post_count server)
;;

let test_release_failure_blocks_successor () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let successor = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let first_slot = "release-failure-first" in
  let successor_slot = "release-failure-successor" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc release failure"
      [ { id = first_slot; base_url = "http://127.0.0.1:9" }
      ; { id = successor_slot; base_url = successor.base_url }
      ]
  in
  let registry = publish_exn ~slot_ids:[ first_slot; successor_slot ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-release-failure" ~registry () in
  let events = ref [] in
  let guard : C.exact_execution_guard =
    { before_dispatch =
        (fun observation ->
           push_event events ("bind:" ^ observation.slot_id);
           Ok C.Fsync_completed)
    ; release_before_dispatch =
        (fun observation ->
           push_event events ("release:" ^ observation.slot_id);
           Error "injected durable release failure")
    ; quarantine = (fun _ _ -> Alcotest.fail "release failure must not relabel")
    }
  in
  let terminal =
    match
      execute_prepared_lane
        ~keeper_name:"keeper-release-failure"
        ~net
        ~clock
        ~exact_execution_guard:guard
        prepared
    with
    | Error (C.Exact_execution_terminal terminal) -> terminal
    | Error _ -> Alcotest.fail "release failure returned the wrong terminal"
    | Ok _ -> Alcotest.fail "release failure incorrectly advanced"
  in
  Alcotest.(check bool)
    "release failure is a persistence terminal"
    true
    (terminal.cause = Keeper_event_queue_state.Terminal_persistence_failed);
  Alcotest.(check string) "release failure retains A" first_slot terminal.slot_id;
  Alcotest.(check (list string))
    "successor is never bound"
    [ "bind:" ^ first_slot; "release:" ^ first_slot ]
    !events;
  Alcotest.(check int) "release failure prevents successor POST" 0 (F.post_count successor)
;;

let test_domain_invalid_output_advances_to_declared_successor () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let invalid = F.start_server ~sw ~net ~clock (F.Reply domain_invalid_response) in
  let successor = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let first_slot = "domain-invalid" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc domain validation failover"
      [ { id = first_slot; base_url = invalid.base_url }
      ; { id = "declared-domain-successor"; base_url = successor.base_url }
      ]
  in
  let registry =
    publish_exn
      ~slot_ids:[ first_slot; "declared-domain-successor" ]
      snapshot
  in
  let prepared = prepare_exn ~keeper_name:"keeper-domain-invalid" ~registry () in
  let quarantined = ref [] in
  let events = ref [] in
  let guard : C.exact_execution_guard =
    { before_dispatch =
        (fun observation ->
           push_event events ("bind:" ^ observation.slot_id);
           Ok C.Fsync_completed)
    ; release_before_dispatch =
        (fun observation ->
           push_event events ("release:" ^ observation.slot_id);
           Ok C.Fsync_completed)
    ; quarantine =
        (fun cause observation ->
           quarantined := (cause, observation.slot_id) :: !quarantined;
           Ok C.Fsync_completed)
    }
  in
  (match
     execute_prepared_lane
       ~keeper_name:"keeper-domain-invalid"
       ~net
       ~clock
       ~exact_execution_guard:guard
       prepared
   with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "declared semantic successor did not complete");
  Alcotest.(check int) "domain-invalid target posts once" 1 (F.post_count invalid);
  Alcotest.(check int) "declared successor posts once" 1 (F.post_count successor);
  Alcotest.(check bool)
    "semantic rejection is not terminally quarantined"
    true
    (List.is_empty !quarantined);
  Alcotest.(check (list string))
    "semantic successor releases A before binding B"
    [ "bind:" ^ first_slot
    ; "release:" ^ first_slot
    ; "bind:declared-domain-successor"
    ]
    (List.rev !events)
;;

let test_semantic_exhaustion_terminalizes_final_bound () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let first = F.start_server ~sw ~net ~clock (F.Reply domain_invalid_response) in
  let final = F.start_server ~sw ~net ~clock (F.Reply domain_invalid_response) in
  let first_slot = "semantic-exhaustion-first" in
  let final_slot = "semantic-exhaustion-final" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc semantic exhaustion"
      [ { id = first_slot; base_url = first.base_url }
      ; { id = final_slot; base_url = final.base_url }
      ]
  in
  let registry = publish_exn ~slot_ids:[ first_slot; final_slot ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-semantic-exhaustion" ~registry () in
  let events = ref [] in
  let guard : C.exact_execution_guard =
    { before_dispatch =
        (fun observation ->
           push_event events ("bind:" ^ observation.slot_id);
           Ok C.Fsync_completed)
    ; release_before_dispatch =
        (fun observation ->
           push_event events ("release:" ^ observation.slot_id);
           Ok C.Fsync_completed)
    ; quarantine =
        (fun _ observation ->
           push_event events ("quarantine:" ^ observation.slot_id);
           Ok C.Fsync_completed)
    }
  in
  (match
     execute_prepared_lane
       ~keeper_name:"keeper-semantic-exhaustion"
       ~net
       ~clock
       ~exact_execution_guard:guard
       prepared
   with
   | Error (C.Exact_execution_terminal terminal) ->
     Alcotest.(check bool)
       "semantic exhaustion is domain-invalid"
       true
       (terminal.cause = Keeper_event_queue_state.Domain_invalid_output);
     Alcotest.(check string) "final bound is terminalized" final_slot terminal.slot_id
   | Error _ -> Alcotest.fail "semantic exhaustion returned the wrong typed failure"
   | Ok _ -> Alcotest.fail "semantic exhaustion unexpectedly succeeded");
  Alcotest.(check (list string))
    "semantic exhaustion releases A and quarantines B"
    [ "bind:" ^ first_slot
    ; "release:" ^ first_slot
    ; "bind:" ^ final_slot
    ; "quarantine:" ^ final_slot
    ]
    (List.rev !events)
;;

let test_final_oas_flow_failure_is_generic_source_terminal () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let failed = F.start_server ~sw ~net ~clock F.Abort_after_request in
  let successor = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let first_slot = "generic-flow-failure" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc generic OAS flow failure"
      [ { id = first_slot; base_url = failed.base_url }
      ; { id = "forbidden-failure-successor"; base_url = successor.base_url }
      ]
  in
  let registry =
    publish_exn
      ~slot_ids:[ first_slot; "forbidden-failure-successor" ]
      snapshot
  in
  let prepared = prepare_exn ~keeper_name:"keeper-flow-failure" ~registry () in
  let quarantined = ref [] in
  let guard : C.exact_execution_guard =
    { before_dispatch = (fun _ -> Ok C.Fsync_completed)
    ; release_before_dispatch =
        (fun _ -> Alcotest.fail "terminal OAS flow failure must not advance")
    ; quarantine =
        (fun cause observation ->
           quarantined := (cause, observation.slot_id) :: !quarantined;
           Ok C.Fsync_completed)
    }
  in
  let terminal =
    match
      execute_prepared_lane
        ~keeper_name:"keeper-flow-failure"
        ~net
        ~clock
        ~exact_execution_guard:guard
        prepared
    with
    | Error (C.Exact_execution_terminal terminal) -> terminal
    | Error _ -> Alcotest.fail "OAS flow failure returned the wrong failure"
    | Ok _ -> Alcotest.fail "failed OAS flow unexpectedly succeeded"
  in
  Alcotest.(check bool)
    "generic terminal does not claim receipt phase"
    true
    (terminal.cause = Keeper_event_queue_state.Exact_execution_failed);
  Alcotest.(check string) "generic terminal retains bound slot" first_slot terminal.slot_id;
  Alcotest.(check int) "failed request posts once" 1 (F.post_count failed);
  Alcotest.(check int) "terminal flow failure never advances" 0 (F.post_count successor);
  Alcotest.(check bool)
    "generic terminal quarantines one identity"
    true
    (List.rev !quarantined
     = [ Keeper_event_queue_state.Exact_execution_failed, first_slot ])
;;

let test_cancellation_preserves_lifecycle_authorized_identity () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let hold_response, _resolve_hold_response = Eio.Promise.create () in
  let first =
    F.start_server
      ~on_request_before_reply:(fun () -> Eio.Promise.await hold_response)
      ~sw
      ~net
      ~clock
      (F.Reply valid_response)
  in
  let successor = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let first_slot = "cancelled-bound-slot" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc bound cancellation"
      [ { id = first_slot; base_url = first.base_url }
      ; { id = "forbidden-cancel-successor"; base_url = successor.base_url }
      ]
  in
  let registry =
    publish_exn
      ~slot_ids:[ first_slot; "forbidden-cancel-successor" ]
      snapshot
  in
  let prepared = prepare_exn ~keeper_name:"keeper-cancelled" ~registry () in
  let authorized = ref [] in
  let cancel_context, resolve_cancel_context = Eio.Promise.create () in
  let execution =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Eio.Cancel.sub (fun context ->
        Eio.Promise.resolve resolve_cancel_context context;
        C.execute_prepared_lane
          ~keeper_name:"keeper-cancelled"
          ~net
          ~clock
          ~before_dispatch_authority:(fun observation ->
            authorized := observation.slot_id :: !authorized;
            Ok ())
          prepared))
  in
  let result =
    try
      Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        let context = Eio.Promise.await cancel_context in
        F.await_first_request first;
        Eio.Cancel.cancel context Cancel_after_request_arrived;
        Eio.Promise.await_exn execution)
    with
    | Eio.Time.Timeout -> Alcotest.fail "cancellation watchdog expired"
  in
  let terminal =
    match result with
    | Error (C.Exact_execution_terminal terminal) -> terminal
    | Error _ -> Alcotest.fail "cancellation returned the wrong terminal"
    | Ok _ -> Alcotest.fail "cancelled flow unexpectedly succeeded"
  in
  Alcotest.(check bool)
    "cancellation terminal is phase-neutral"
    true
    (terminal.cause = Keeper_event_queue_state.Exact_execution_cancelled);
  Alcotest.(check (list string))
    "only first identity was lifecycle-authorized"
    [ first_slot ]
    (List.rev !authorized);
  Alcotest.(check int) "cancelled request posts once" 1 (F.post_count first);
  Alcotest.(check int) "cancellation never dispatches successor" 0 (F.post_count successor)
;;


let test_post_success_commit_claim_blocks_reject () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let keeper_name = "keeper-post-success-commit-wins" in
  let slot_id = "post-success-commit-wins" in
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc post-success commit wins"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name ~registry () in
  let quarantine_calls = ref 0 in
  let guard : C.exact_execution_guard =
    { F.permissive_exact_execution_guard with
      quarantine =
        (fun _cause _observation ->
           incr quarantine_calls;
           Ok C.Fsync_completed)
    }
  in
  let completed =
    execute_prepared_lane
      ~keeper_name
      ~net
      ~clock
      ~exact_execution_guard:guard
      prepared
    |> completed_exn
  in
  let terminalizer = C.completed_post_success_terminalizer completed in
  (match C.claim_post_success_commit terminalizer with
   | C.Commit_claim_acquired -> ()
   | C.Commit_claim_in_progress _
   | C.Commit_claim_already_committed
   | C.Commit_claim_rejected _ ->
     Alcotest.fail "open post-success disposition did not grant commit claim");
  (match C.mark_post_success_checkpoint_installed terminalizer with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "installed commit mark failed: %s" detail);
  let completion =
    match
      C.terminalize_post_success
        terminalizer
        Keeper_event_queue_state.Commit_admission_unavailable
    with
    | C.Terminalization_commit_in_progress waiter -> waiter
    | C.Terminalized _
    | C.Terminalization_already_committed
    | C.Terminalization_persistence_failed _
    | C.Terminalization_invariant_failed _ ->
      Alcotest.fail "reject crossed an installed commit claim"
  in
  let pending = C.For_testing.post_success_snapshot terminalizer in
  Alcotest.(check bool)
    "installed checkpoint remains pending valid"
    true
    (pending.phase = C.Phase_installed_pending_valid);
  Alcotest.(check int) "reject settlement has not run" 0 pending.domain_rejected_attempts;
  Alcotest.(check int) "quarantine has not run" 0 !quarantine_calls;
  (match C.complete_post_success_commit terminalizer with
   | Ok () -> ()
   | Error detail ->
     Alcotest.failf "post-success completion failed: %s" detail);
  Eio.Promise.await completion;
  (match
     C.terminalize_post_success
       terminalizer
       Keeper_event_queue_state.Checkpoint_persistence_failed
   with
   | C.Terminalization_already_committed -> ()
   | C.Terminalized _
   | C.Terminalization_commit_in_progress _
   | C.Terminalization_persistence_failed _
   | C.Terminalization_invariant_failed _ ->
     Alcotest.fail "committed checkpoint was downgraded by a later reject");
  let committed = C.For_testing.post_success_snapshot terminalizer in
  Alcotest.(check bool)
    "post-success disposition is committed"
    true
    (committed.phase = C.Phase_committed);
  Alcotest.(check int) "Domain_valid runs once" 1 committed.domain_valid_attempts;
  Alcotest.(check int) "Domain_rejected never runs" 0 committed.domain_rejected_attempts;
  Alcotest.(check int) "quarantine never runs" 0 !quarantine_calls
;;

let () =
  Alcotest.run
    "compaction exact-flow conformance"
    [ ( "preparation"
      , [ Alcotest.test_case
            "missing lane is explicit"
            `Quick
            test_missing_compaction_lane_is_explicit_degraded_state
        ; Alcotest.test_case
            "order and generation freeze before attempt allocation"
            `Quick
            test_preparation_freezes_order_generation_and_defers_attempt_identity
        ; Alcotest.test_case
            "replacement cannot mix prepared generation"
            `Quick
            test_published_replacement_cannot_mix_prepared_generation
        ] )
    ; ( "durable flow callbacks"
      , [ Alcotest.test_case
            "release precedes successor bind and POST"
            `Quick
            test_durable_release_precedes_successor_bind_and_post
        ; Alcotest.test_case
            "bind failure prevents POST"
            `Quick
            test_bind_failure_prevents_post
        ; Alcotest.test_case
            "lifecycle authority permits dispatch without queue guard"
            `Quick
            test_dispatch_authority_without_queue_guard
        ; Alcotest.test_case
            "release failure blocks successor"
            `Quick
            test_release_failure_blocks_successor
        ] )
    ; ( "terminal ownership"
      , [ Alcotest.test_case
            "domain invalidity advances to declared successor"
            `Quick
            test_domain_invalid_output_advances_to_declared_successor
        ; Alcotest.test_case
            "final OAS failure is generic terminal"
            `Quick
            test_final_oas_flow_failure_is_generic_source_terminal
        ; Alcotest.test_case
            "semantic exhaustion terminalizes final bound"
            `Quick
            test_semantic_exhaustion_terminalizes_final_bound
        ; Alcotest.test_case
            "cancellation preserves lifecycle-authorized identity"
            `Quick
            test_cancellation_preserves_lifecycle_authorized_identity
        ; Alcotest.test_case
            "commit claim blocks reject after install"
            `Quick
            test_post_success_commit_claim_blocks_reject
        ] )
    ]
;;
