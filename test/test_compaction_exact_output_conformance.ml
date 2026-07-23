(** MASC-owned composition proof for the compaction OAS exact-flow boundary.

    OAS owns admission, affine attempts, execute-once, advancement, and receipt
    semantics. These tests observe only MASC-owned ordered opaque slot identity,
    durable bind/release/quarantine callbacks, domain validation, registry
    generation, and source terminalization. *)

open Masc

module C = Keeper_compaction_llm_summarizer
module F = Compaction_exact_output_fixture
module P = Keeper_event_queue_persistence
module Q = Keeper_event_queue
module Registry = Runtime_exact_output_registry
module S = Keeper_structured_output_schema
module T = Agent_sdk.Types
module U = Keeper_compaction_unit

exception Cancel_after_request_arrived

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

let claim_manual_lease ~base_path ~keeper_name =
  let stimulus : Q.stimulus =
    { post_id = "manual-compaction"
    ; urgency = Q.Immediate
    ; arrived_at = 1.0
    ; payload = Q.Manual_compaction_requested
    }
  in
  (match
     P.update_checked_result
       ~base_path
       ~keeper_name
       (fun pending -> Ok (Q.enqueue pending stimulus))
   with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "manual stimulus persist failed: %s" detail);
  match
    P.claim_when_result
      ~base_path
      ~keeper_name
      ~claimed_at:2.0
      ~ready:(fun _ -> true)
      ()
  with
  | Ok (Some lease) -> lease
  | Ok None -> Alcotest.fail "manual lease was not claimed"
  | Error detail -> Alcotest.failf "manual lease claim failed: %s" detail
;;

let persisted_checkpoint_source_exn trace_id =
  match Keeper_id.Trace_id.of_string trace_id with
  | Error detail -> Alcotest.failf "checkpoint source trace id failed: %s" detail
  | Ok trace_id ->
    (match
       Keeper_checkpoint_ref.of_persisted
         ~trace_id
         ~generation:1
         ~turn_count:1
         ~sha256:(String.make 64 'a')
     with
     | Ok source -> source
     | Error _ -> Alcotest.fail "persisted checkpoint source ref failed")
;;

let settle_terminal_disposition_result
      ~base_path
      ~keeper_name
      ~lease
      ~source
      ~(terminal : P.exact_execution_terminal)
      ~settled_at
  =
  let disposition =
    match
      P.prepare_exact_source_disposition_result
        ~base_path
        ~keeper_name
        ~lease
        ~source
        ~terminal
        ~semantic:P.Exact_no_compaction
        ~prepared_at:settled_at
        ()
    with
    | Error detail -> Alcotest.failf "terminal disposition preparation failed: %s" detail
    | Ok (_, P.Visible_sync_unconfirmed detail) ->
      Alcotest.failf "terminal disposition preparation durability unknown: %s" detail
    | Ok (disposition, P.Fsync_completed) -> disposition
  in
  P.finalize_exact_source_disposition_result
    ~base_path
    ~keeper_name
    ~settled_at
    ~lease
    ~disposition_id:disposition.disposition_id
    ()
;;

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

let prepare_exn ~keeper_name ~registry =
  match
    C.prepare_lane
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

let observation_exn prepared slot_id =
  C.For_testing.attempt_observations prepared
  |> List.find_opt (fun (observation : C.attempt_observation) ->
    String.equal observation.slot_id slot_id)
  |> function
  | Some observation -> observation
  | None -> Alcotest.failf "missing OAS flow attempt identity for %s" slot_id
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
  match
    C.prepare_lane
      ~keeper_name:"keeper-missing-compaction-lane"
      ~registry
      ~lane_id:"compaction_exact"
      ~units
  with
  | Error C.Exact_lane_unconfigured -> ()
  | Error _ -> Alcotest.fail "missing lane returned the wrong typed failure"
  | Ok _ -> Alcotest.fail "missing lane must not be synthesized"
;;

let test_preparation_freezes_order_generation_and_unique_call_ids () =
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
  let prepared = prepare_exn ~keeper_name:"keeper-preparation" ~registry in
  Alcotest.(check (list string))
    "MASC opaque declaration order"
    [ "prepare-first"; "prepare-second" ]
    (C.For_testing.flow_slot_ids prepared);
  Alcotest.(check int64)
    "one immutable MASC registry generation"
    (Registry.generation registry)
    (C.For_testing.registry_generation prepared);
  (match C.For_testing.attempt_observations prepared with
   | [ first_observation; second_observation ] ->
     check_identity "first attempt" first_observation;
     check_identity "second attempt" second_observation;
     Alcotest.(check bool)
       "candidate call ids are unique"
       true
       (not (String.equal first_observation.call_id second_observation.call_id))
   | _ -> Alcotest.fail "prepared OAS flow did not retain two candidate identities");
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
  let prepared_a = prepare_exn ~keeper_name:"keeper-frozen-a" ~registry:registry_a in
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
  let prepared = prepare_exn ~keeper_name:"keeper-advance-order" ~registry in
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
  let prepared = prepare_exn ~keeper_name:"keeper-bind-failure" ~registry in
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
   | Error C.Exact_execution_guard_failed -> ()
   | Error _ -> Alcotest.fail "bind failure returned the wrong typed failure"
   | Ok _ -> Alcotest.fail "bind failure unexpectedly executed");
  Alcotest.(check int) "bind failure prevents POST" 0 (F.post_count server)
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
  let prepared = prepare_exn ~keeper_name:"keeper-release-failure" ~registry in
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

let test_domain_invalid_output_never_reenters_failover () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let invalid = F.start_server ~sw ~net ~clock (F.Reply domain_invalid_response) in
  let successor = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let first_slot = "domain-invalid" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc domain validation terminal"
      [ { id = first_slot; base_url = invalid.base_url }
      ; { id = "forbidden-domain-successor"; base_url = successor.base_url }
      ]
  in
  let registry =
    publish_exn
      ~slot_ids:[ first_slot; "forbidden-domain-successor" ]
      snapshot
  in
  let prepared = prepare_exn ~keeper_name:"keeper-domain-invalid" ~registry in
  let quarantined = ref [] in
  let guard : C.exact_execution_guard =
    { before_dispatch = (fun _ -> Ok C.Fsync_completed)
    ; release_before_dispatch =
        (fun _ -> Alcotest.fail "domain validation is outside OAS advancement")
    ; quarantine =
        (fun cause observation ->
           quarantined := (cause, observation.slot_id) :: !quarantined;
           Ok C.Fsync_completed)
    }
  in
  let terminal =
    match
      execute_prepared_lane
        ~keeper_name:"keeper-domain-invalid"
        ~net
        ~clock
        ~exact_execution_guard:guard
        prepared
    with
    | Error (C.Exact_execution_terminal terminal) -> terminal
    | Error _ -> Alcotest.fail "domain invalidity returned the wrong failure"
    | Ok _ -> Alcotest.fail "domain-invalid output unexpectedly succeeded"
  in
  Alcotest.(check bool)
    "domain terminal cause"
    true
    (terminal.cause = Keeper_event_queue_state.Domain_invalid_output);
  Alcotest.(check string) "domain terminal retains bound slot" first_slot terminal.slot_id;
  Alcotest.(check int) "domain-invalid target posts once" 1 (F.post_count invalid);
  Alcotest.(check int) "domain invalidity never fails over" 0 (F.post_count successor);
  Alcotest.(check bool)
    "only bound identity quarantined"
    true
    (List.rev !quarantined
     = [ Keeper_event_queue_state.Domain_invalid_output, first_slot ])
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
  let prepared = prepare_exn ~keeper_name:"keeper-flow-failure" ~registry in
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

let test_cancellation_quarantines_only_bound_identity () =
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
  let prepared = prepare_exn ~keeper_name:"keeper-cancelled" ~registry in
  let bound = ref [] in
  let quarantined = ref [] in
  let guard : C.exact_execution_guard =
    { before_dispatch =
        (fun observation ->
           bound := observation.slot_id :: !bound;
           Ok C.Fsync_completed)
    ; release_before_dispatch =
        (fun _ -> Alcotest.fail "cancelled bound identity must not advance")
    ; quarantine =
        (fun cause observation ->
           quarantined := (cause, observation.slot_id) :: !quarantined;
           Ok C.Fsync_completed)
    }
  in
  let cancel_context, resolve_cancel_context = Eio.Promise.create () in
  let execution =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Eio.Cancel.sub (fun context ->
        Eio.Promise.resolve resolve_cancel_context context;
        execute_prepared_lane
          ~keeper_name:"keeper-cancelled"
          ~net
          ~clock
          ~exact_execution_guard:guard
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
  Alcotest.(check (list string)) "only first identity was bound" [ first_slot ] (List.rev !bound);
  Alcotest.(check bool)
    "only the bound identity was quarantined"
    true
    (List.rev !quarantined
     = [ Keeper_event_queue_state.Exact_execution_cancelled, first_slot ]);
  Alcotest.(check int) "cancelled request posts once" 1 (F.post_count first);
  Alcotest.(check int) "cancellation never dispatches successor" 0 (F.post_count successor)
;;

let test_independent_preparations_do_not_share_call_identity () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let slot_id = "independent-flow-slot" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc flow non-sharing"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let keeper_a = prepare_exn ~keeper_name:"keeper-a" ~registry in
  let keeper_b = prepare_exn ~keeper_name:"keeper-b" ~registry in
  let a = observation_exn keeper_a slot_id in
  let b = observation_exn keeper_b slot_id in
  Alcotest.(check bool)
    "independent flows own distinct call ids"
    true
    (not (String.equal a.call_id b.call_id));
  let result_a, result_b =
    Eio.Fiber.pair
      (fun () -> execute_prepared_lane ~keeper_name:"keeper-a" ~net ~clock keeper_a)
      (fun () -> execute_prepared_lane ~keeper_name:"keeper-b" ~net ~clock keeper_b)
  in
  ignore (completed_exn result_a : C.completed_plan);
  ignore (completed_exn result_b : C.completed_plan);
  Alcotest.(check int) "independent flows post independently" 2 (F.post_count server)
;;

let test_same_flow_concurrent_loser_mutates_no_queue () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  with_temp_dir "masc-same-flow-affinity"
  @@ fun base_path ->
  let keeper_name = "keeper-same-flow-affinity" in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  let server =
    F.start_server ~sw ~net ~clock (F.Delay_then_reply (0.05, valid_response))
  in
  let slot_id = "same-flow-slot" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc same-flow affinity"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name ~registry in
  let durable_guard =
    Keeper_heartbeat_loop.For_testing.exact_execution_guard
      ~base_path
      ~keeper_name
      ~lease
  in
  let bind_mutations = Atomic.make 0 in
  let release_mutations = Atomic.make 0 in
  let quarantine_mutations = Atomic.make 0 in
  let guard : C.exact_execution_guard =
    { before_dispatch =
        (fun observation ->
           Atomic.incr bind_mutations;
           durable_guard.before_dispatch observation)
    ; release_before_dispatch =
        (fun observation ->
           Atomic.incr release_mutations;
           durable_guard.release_before_dispatch observation)
    ; quarantine =
        (fun cause observation ->
           Atomic.incr quarantine_mutations;
           durable_guard.quarantine cause observation)
    }
  in
  let first, second =
    Eio.Fiber.pair
      (fun () ->
         execute_prepared_lane
           ~keeper_name
           ~net
           ~clock
           ~exact_execution_guard:guard
           prepared)
      (fun () ->
         execute_prepared_lane
           ~keeper_name
           ~net
           ~clock
           ~exact_execution_guard:guard
           prepared)
  in
  (match first, second with
   | Ok _, Error C.Exact_flow_already_started
   | Error C.Exact_flow_already_started, Ok _ ->
     ()
   | _ -> Alcotest.fail "same flow must have one owner and one affine loser");
  Alcotest.(check int) "one owner performs one durable bind" 1 (Atomic.get bind_mutations);
  Alcotest.(check int) "loser performs no release mutation" 0 (Atomic.get release_mutations);
  Alcotest.(check int)
    "loser performs no quarantine mutation"
    0
    (Atomic.get quarantine_mutations);
  Alcotest.(check int) "same flow performs one POST" 1 (F.post_count server);
  match P.exact_execution_binding_result ~base_path ~keeper_name with
  | Ok (Some binding) ->
    Alcotest.(check string) "durable binding retains winner slot" slot_id binding.slot_id
  | Ok None -> Alcotest.fail "winner durable binding is missing"
  | Error detail -> Alcotest.failf "winner binding reload failed: %s" detail
;;

let test_heartbeat_guard_binds_before_post () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  with_temp_dir "masc-heartbeat-bind-before-post"
  @@ fun base_path ->
  let keeper_name = "keeper-heartbeat-bind-before-post" in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  let slot_id = "heartbeat-bind-before-post" in
  let expected_observation = ref None in
  let durable_binding_seen = Atomic.make false in
  let server =
    F.start_server
      ~on_request_before_reply:(fun () ->
        match
          !expected_observation,
          P.exact_execution_binding_result ~base_path ~keeper_name
        with
        | Some (observation : C.attempt_observation),
          Ok (Some (binding : P.exact_execution_binding))
          when binding.status = P.Dispatch_uncertain
               && String.equal binding.slot_id observation.slot_id
               && String.equal binding.call_id observation.call_id
               && String.equal
                    binding.plan_fingerprint
                    observation.receipt_plan_fingerprint
               && String.equal
                    binding.request_body_sha256
                    observation.receipt_request_body_sha256 ->
          Atomic.set durable_binding_seen true
        | _ -> ())
      ~sw
      ~net
      ~clock
      (F.Reply valid_response)
  in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc heartbeat durable bind order"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name ~registry in
  expected_observation := Some (observation_exn prepared slot_id);
  let guard =
    Keeper_heartbeat_loop.For_testing.exact_execution_guard
      ~base_path
      ~keeper_name
      ~lease
  in
  ignore
    (execute_prepared_lane
       ~keeper_name
       ~net
       ~clock
       ~exact_execution_guard:guard
       prepared
     |> completed_exn
      : C.completed_plan);
  Alcotest.(check bool)
    "durable binding exists when POST arrives"
    true
    (Atomic.get durable_binding_seen);
  Alcotest.(check int) "guarded flow posts once" 1 (F.post_count server)
;;

let test_post_success_terminalization_is_canonical_and_durable () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  with_temp_dir "masc-post-success-terminal"
  @@ fun base_path ->
  let keeper_name = "keeper-post-success-terminal" in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  let slot_id = "post-success-terminal" in
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc post-success terminal"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name ~registry in
  let durable_guard =
    Keeper_heartbeat_loop.For_testing.exact_execution_guard
      ~base_path
      ~keeper_name
      ~lease
  in
  let quarantine_calls = ref 0 in
  let guard : C.exact_execution_guard =
    { durable_guard with
      quarantine =
        (fun cause observation ->
           incr quarantine_calls;
           durable_guard.quarantine cause observation)
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
  let first =
    C.terminalize_post_success
      terminalizer
      Keeper_event_queue_state.Invalid_structural_evidence
  in
  let replay =
    C.terminalize_post_success
      terminalizer
      Keeper_event_queue_state.Checkpoint_persistence_failed
  in
  Alcotest.(check int) "terminalizer quarantines once" 1 !quarantine_calls;
  Alcotest.(check bool) "terminalizer retains first canonical cause" true (first = replay);
  let source = persisted_checkpoint_source_exn "trace-post-success-terminal" in
  (match
     settle_terminal_disposition_result
       ~base_path
       ~keeper_name
       ~lease
       ~source
       ~terminal:replay
       ~settled_at:4.0
   with
   | Ok (P.Settled receipt) ->
     (match P.exact_execution_binding_result ~base_path ~keeper_name with
      | Ok None -> ()
      | Ok (Some _) -> Alcotest.fail "terminal settlement retained binding"
      | Error detail -> Alcotest.failf "settled binding reload failed: %s" detail);
     (match P.active_lease_result ~base_path ~keeper_name with
      | Ok None -> ()
      | Ok (Some _) -> Alcotest.fail "terminal settlement retained lease"
      | Error detail -> Alcotest.failf "settled lease reload failed: %s" detail);
     let state =
       match P.load_state_result ~base_path ~keeper_name with
       | Ok state -> state
       | Error detail -> Alcotest.failf "canonical state reload failed: %s" detail
     in
     (match Keeper_event_queue_state.transition_outbox state with
      | [ { receipt = durable_receipt; _ } ] ->
        Alcotest.(check bool)
          "canonical terminal receipt is durable"
          true
          (receipt = durable_receipt);
        (match durable_receipt.settlement with
         | P.Settle_exact
             { outcome = P.Terminal cause
             ; slot_id = durable_slot
             ; call_id = durable_call
             ; _
             } ->
           Alcotest.(check bool)
             "durable settlement retains canonical terminal identity"
             true
             (cause = first.cause
              && String.equal durable_slot first.slot_id
              && String.equal durable_call first.call_id)
         | _ -> Alcotest.fail "durable receipt lost exact terminal")
      | _ -> Alcotest.fail "canonical terminal outbox receipt is missing")
   | Ok (P.Already_settled _) ->
     Alcotest.fail "first terminal settlement was already settled"
   | Ok (P.Committed_followup_failed { detail; _ }) ->
     Alcotest.failf "terminal settlement follow-up failed: %s" detail
   | Error detail -> Alcotest.failf "terminal settlement failed: %s" detail)
;;

let test_post_success_terminalization_overlap_is_affine_and_durable () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  with_temp_dir "masc-post-success-terminal-overlap"
  @@ fun base_path ->
  let keeper_name = "keeper-post-success-terminal-overlap" in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  let slot_id = "post-success-terminal-overlap" in
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc post-success terminal overlap"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name ~registry in
  let durable_guard =
    Keeper_heartbeat_loop.For_testing.exact_execution_guard
      ~base_path
      ~keeper_name
      ~lease
  in
  let quarantine_entered, resolve_quarantine_entered = Eio.Promise.create () in
  let release_quarantine, resolve_release_quarantine = Eio.Promise.create () in
  let quarantine_calls = ref 0 in
  let guard : C.exact_execution_guard =
    { durable_guard with
      quarantine =
        (fun cause observation ->
           incr quarantine_calls;
           Eio.Promise.resolve resolve_quarantine_entered ();
           Eio.Promise.await release_quarantine;
           durable_guard.quarantine cause observation)
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
  let first_result, resolve_first_result = Eio.Promise.create () in
  let second_started, resolve_second_started = Eio.Promise.create () in
  let second_result, resolve_second_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    C.terminalize_post_success
      terminalizer
      Keeper_event_queue_state.Invalid_structural_evidence
    |> Eio.Promise.resolve resolve_first_result);
  Eio.Promise.await quarantine_entered;
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Promise.resolve resolve_second_started ();
    C.terminalize_post_success
      terminalizer
      Keeper_event_queue_state.Checkpoint_persistence_failed
    |> Eio.Promise.resolve resolve_second_result);
  Eio.Promise.await second_started;
  Eio.Fiber.yield ();
  Eio.Promise.resolve resolve_release_quarantine ();
  let first = Eio.Promise.await first_result in
  let second = Eio.Promise.await second_result in
  Alcotest.(check int) "overlap performs one quarantine" 1 !quarantine_calls;
  Alcotest.(check bool)
    "overlap returns one canonical terminal"
    true
    (first = second);
  Alcotest.(check bool)
    "first concurrent cause remains canonical"
    true
    (first.cause = Keeper_event_queue_state.Invalid_structural_evidence);
  let source = persisted_checkpoint_source_exn "trace-post-success-terminal-overlap" in
  (match
     settle_terminal_disposition_result
       ~base_path
       ~keeper_name
       ~lease
       ~source
       ~terminal:second
       ~settled_at:5.0
   with
   | Ok (P.Settled _) -> ()
   | Ok (P.Already_settled _) ->
     Alcotest.fail "first overlap settlement was already settled"
   | Ok (P.Committed_followup_failed { detail; _ }) ->
     Alcotest.failf "overlap settlement follow-up failed: %s" detail
   | Error detail -> Alcotest.failf "overlap settlement failed: %s" detail);
  (match P.exact_execution_binding_result ~base_path ~keeper_name with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "overlap settlement retained exact binding"
   | Error detail -> Alcotest.failf "overlap binding reload failed: %s" detail);
  match P.transition_outbox_result ~base_path ~keeper_name with
  | Ok [ _ ] -> ()
  | Ok _ -> Alcotest.fail "overlap produced other than one durable settlement"
  | Error detail -> Alcotest.failf "overlap outbox reload failed: %s" detail
;;

let test_post_success_terminalization_failures_preserve_full_binding () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let cases =
    [ "error", (fun _cause _observation -> Error "injected quarantine error")
    ; "exception", (fun _cause _observation -> failwith "injected quarantine exception")
    ]
  in
  List.iteri
    (fun index (label, quarantine) ->
       with_temp_dir ("masc-post-success-terminal-" ^ label)
       @@ fun base_path ->
       let keeper_name = "keeper-post-success-terminal-" ^ label in
       let lease = claim_manual_lease ~base_path ~keeper_name in
       let slot_id = Printf.sprintf "post-success-terminal-%s-%d" label index in
       let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
       let snapshot =
         F.resolver_snapshot
           ~source:("masc post-success terminal " ^ label)
           [ { id = slot_id; base_url = server.base_url } ]
       in
       let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
       let prepared = prepare_exn ~keeper_name ~registry in
       let durable_guard =
         Keeper_heartbeat_loop.For_testing.exact_execution_guard
           ~base_path
           ~keeper_name
           ~lease
       in
       let quarantine_calls = ref 0 in
       let guard : C.exact_execution_guard =
         { durable_guard with
           quarantine =
             (fun cause observation ->
                incr quarantine_calls;
                quarantine cause observation)
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
       let observation = C.completed_attempt_observation completed in
       let terminalizer = C.completed_post_success_terminalizer completed in
       let first =
         C.terminalize_post_success
           terminalizer
           Keeper_event_queue_state.Invalid_structural_evidence
       in
       let replay =
         C.terminalize_post_success
           terminalizer
           Keeper_event_queue_state.Checkpoint_persistence_failed
       in
       Alcotest.(check int) (label ^ " quarantine runs once") 1 !quarantine_calls;
       Alcotest.(check bool)
         (label ^ " replay returns canonical terminal")
         true
         (first = replay);
       Alcotest.(check bool)
         (label ^ " first cause remains canonical")
         true
         (first.cause = Keeper_event_queue_state.Invalid_structural_evidence);
       match P.exact_execution_binding_result ~base_path ~keeper_name with
       | Ok
           (Some
             { slot_id = durable_slot_id
             ; call_id = durable_call_id
             ; plan_fingerprint
             ; request_body_sha256
             ; status = P.Dispatch_uncertain
             ; _
             }) ->
         Alcotest.(check string)
           (label ^ " retains slot identity")
           observation.slot_id
           durable_slot_id;
         Alcotest.(check string)
           (label ^ " retains call identity")
           observation.call_id
           durable_call_id;
         Alcotest.(check string)
           (label ^ " retains plan identity")
           observation.receipt_plan_fingerprint
           plan_fingerprint;
         Alcotest.(check string)
           (label ^ " retains request identity")
           observation.receipt_request_body_sha256
           request_body_sha256
       | Ok (Some _) ->
         Alcotest.failf "%s quarantine failure did not remain dispatch-uncertain" label
       | Ok None -> Alcotest.failf "%s quarantine failure removed the binding" label
       | Error detail ->
         Alcotest.failf "%s quarantine failure binding reload failed: %s" label detail)
    cases
;;

let test_visible_sync_uncertainty_seams () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let bind_visibility () =
    with_temp_dir "masc-visible-bind"
    @@ fun base_path ->
    let keeper_name = "keeper-visible-bind" in
    let lease = claim_manual_lease ~base_path ~keeper_name in
    let slot_id = "visible-bind" in
    let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
    let snapshot =
      F.resolver_snapshot
        ~source:"masc visible bind"
        [ { id = slot_id; base_url = server.base_url } ]
    in
    let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
    let prepared = prepare_exn ~keeper_name ~registry in
    let observation = observation_exn prepared slot_id in
    let durable_guard =
      Keeper_heartbeat_loop.For_testing.exact_execution_guard
        ~base_path
        ~keeper_name
        ~lease
    in
    let bind_calls = ref 0 in
    let guard : C.exact_execution_guard =
      { durable_guard with
        before_dispatch =
          (fun candidate ->
             incr bind_calls;
             match durable_guard.before_dispatch candidate with
             | Ok C.Fsync_completed ->
               Ok (C.Visible_sync_unconfirmed "injected bind visibility uncertainty")
             | Ok (C.Visible_sync_unconfirmed _ as outcome) -> Ok outcome
             | Error _ as error -> error)
      }
    in
    let terminal =
      match
        execute_prepared_lane
          ~keeper_name
          ~net
          ~clock
          ~exact_execution_guard:guard
          prepared
      with
      | Error (C.Exact_execution_terminal terminal) -> terminal
      | Error _ -> Alcotest.fail "visible bind returned the wrong terminal"
      | Ok _ -> Alcotest.fail "visible bind unexpectedly dispatched"
    in
    Alcotest.(check int) "visible bind callback runs once" 1 !bind_calls;
    Alcotest.(check int) "visible bind prevents POST" 0 (F.post_count server);
    Alcotest.(check bool)
      "visible bind uses persistence terminal"
      true
      (terminal.cause = Keeper_event_queue_state.Terminal_persistence_failed);
    Alcotest.(check string) "visible bind terminal slot" observation.slot_id terminal.slot_id;
    Alcotest.(check string) "visible bind terminal call" observation.call_id terminal.call_id;
    Alcotest.(check string)
      "visible bind terminal plan"
      observation.receipt_plan_fingerprint
      terminal.plan_fingerprint;
    Alcotest.(check string)
      "visible bind terminal request"
      observation.receipt_request_body_sha256
      terminal.request_body_sha256;
    match P.exact_execution_binding_result ~base_path ~keeper_name with
    | Ok
        (Some
          { status = P.Dispatch_uncertain
          ; slot_id = durable_slot_id
          ; call_id = durable_call_id
          ; plan_fingerprint
          ; request_body_sha256
          ; _
          }) ->
      Alcotest.(check string) "visible bind durable slot" observation.slot_id durable_slot_id;
      Alcotest.(check string) "visible bind durable call" observation.call_id durable_call_id;
      Alcotest.(check string)
        "visible bind durable plan"
        observation.receipt_plan_fingerprint
        plan_fingerprint;
      Alcotest.(check string)
        "visible bind durable request"
        observation.receipt_request_body_sha256
        request_body_sha256
    | Ok (Some _) -> Alcotest.fail "visible bind retained the wrong durable status"
    | Ok None -> Alcotest.fail "visible bind lost durable identity"
    | Error detail -> Alcotest.failf "visible bind reload failed: %s" detail
  in
  let release_visibility () =
    with_temp_dir "masc-visible-release"
    @@ fun base_path ->
    let keeper_name = "keeper-visible-release" in
    let lease = claim_manual_lease ~base_path ~keeper_name in
    let first_slot = "visible-release-first" in
    let successor_slot = "visible-release-successor" in
    let successor = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
    let snapshot =
      F.resolver_snapshot
        ~source:"masc visible release"
        [ { id = first_slot; base_url = "http://127.0.0.1:9" }
        ; { id = successor_slot; base_url = successor.base_url }
        ]
    in
    let registry = publish_exn ~slot_ids:[ first_slot; successor_slot ] snapshot in
    let prepared = prepare_exn ~keeper_name ~registry in
    let first_observation = observation_exn prepared first_slot in
    let durable_guard =
      Keeper_heartbeat_loop.For_testing.exact_execution_guard
        ~base_path
        ~keeper_name
        ~lease
    in
    let bound_slots = ref [] in
    let release_calls = ref 0 in
    let guard : C.exact_execution_guard =
      { before_dispatch =
          (fun candidate ->
             bound_slots := candidate.slot_id :: !bound_slots;
             durable_guard.before_dispatch candidate)
      ; release_before_dispatch =
          (fun candidate ->
             incr release_calls;
             match durable_guard.release_before_dispatch candidate with
             | Ok C.Fsync_completed ->
               Ok (C.Visible_sync_unconfirmed "injected release visibility uncertainty")
             | Ok (C.Visible_sync_unconfirmed _ as outcome) -> Ok outcome
             | Error _ as error -> error)
      ; quarantine = durable_guard.quarantine
      }
    in
    let terminal =
      match
        execute_prepared_lane
          ~keeper_name
          ~net
          ~clock
          ~exact_execution_guard:guard
          prepared
      with
      | Error (C.Exact_execution_terminal terminal) -> terminal
      | Error _ -> Alcotest.fail "visible release returned the wrong terminal"
      | Ok _ -> Alcotest.fail "visible release incorrectly advanced"
    in
    Alcotest.(check (list string))
      "visible release never binds successor"
      [ first_slot ]
      (List.rev !bound_slots);
    Alcotest.(check int) "visible release callback runs once" 1 !release_calls;
    Alcotest.(check int)
      "visible release prevents successor POST"
      0
      (F.post_count successor);
    Alcotest.(check bool)
      "visible release uses persistence terminal"
      true
      (terminal.cause = Keeper_event_queue_state.Terminal_persistence_failed);
    Alcotest.(check string)
      "visible release stays on A slot"
      first_observation.slot_id
      terminal.slot_id;
    Alcotest.(check string)
      "visible release stays on A call"
      first_observation.call_id
      terminal.call_id;
    Alcotest.(check string)
      "visible release stays on A plan"
      first_observation.receipt_plan_fingerprint
      terminal.plan_fingerprint;
    Alcotest.(check string)
      "visible release stays on A request"
      first_observation.receipt_request_body_sha256
      terminal.request_body_sha256
  in
  let quarantine_visibility () =
    with_temp_dir "masc-visible-quarantine"
    @@ fun base_path ->
    let keeper_name = "keeper-visible-quarantine" in
    let lease = claim_manual_lease ~base_path ~keeper_name in
    let slot_id = "visible-quarantine" in
    let server =
      F.start_server ~sw ~net ~clock (F.Reply domain_invalid_response)
    in
    let snapshot =
      F.resolver_snapshot
        ~source:"masc visible quarantine"
        [ { id = slot_id; base_url = server.base_url } ]
    in
    let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
    let prepared = prepare_exn ~keeper_name ~registry in
    let observation = observation_exn prepared slot_id in
    let durable_guard =
      Keeper_heartbeat_loop.For_testing.exact_execution_guard
        ~base_path
        ~keeper_name
        ~lease
    in
    let quarantine_calls = ref 0 in
    let guard : C.exact_execution_guard =
      { durable_guard with
        quarantine =
          (fun cause candidate ->
             incr quarantine_calls;
             match durable_guard.quarantine cause candidate with
             | Ok C.Fsync_completed ->
               Ok (C.Visible_sync_unconfirmed "injected quarantine visibility uncertainty")
             | Ok (C.Visible_sync_unconfirmed _ as outcome) -> Ok outcome
             | Error _ as error -> error)
      }
    in
    let terminal =
      match
        execute_prepared_lane
          ~keeper_name
          ~net
          ~clock
          ~exact_execution_guard:guard
          prepared
      with
      | Error (C.Exact_execution_terminal terminal) -> terminal
      | Error _ -> Alcotest.fail "visible quarantine returned the wrong terminal"
      | Ok _ -> Alcotest.fail "domain-invalid output unexpectedly succeeded"
    in
    Alcotest.(check int) "visible quarantine callback runs once" 1 !quarantine_calls;
    Alcotest.(check int) "visible quarantine follows one POST" 1 (F.post_count server);
    Alcotest.(check bool)
      "visible quarantine preserves original cause"
      true
      (terminal.cause = Keeper_event_queue_state.Domain_invalid_output);
    Alcotest.(check string)
      "visible quarantine preserves slot"
      observation.slot_id
      terminal.slot_id;
    Alcotest.(check string)
      "visible quarantine preserves call"
      observation.call_id
      terminal.call_id;
    Alcotest.(check string)
      "visible quarantine preserves plan"
      observation.receipt_plan_fingerprint
      terminal.plan_fingerprint;
    Alcotest.(check string)
      "visible quarantine preserves request"
      observation.receipt_request_body_sha256
      terminal.request_body_sha256;
    let source = persisted_checkpoint_source_exn "trace-visible-quarantine" in
    let receipt =
      match
        settle_terminal_disposition_result
          ~base_path
          ~keeper_name
          ~lease
          ~source
          ~terminal
          ~settled_at:6.0
      with
      | Ok (P.Settled receipt) -> receipt
      | Ok (P.Already_settled _) ->
        Alcotest.fail "first visible quarantine settlement was already settled"
      | Ok (P.Committed_followup_failed { detail; _ }) ->
        Alcotest.failf "visible quarantine settlement follow-up failed: %s" detail
      | Error detail -> Alcotest.failf "visible quarantine settlement failed: %s" detail
    in
    (match P.exact_execution_binding_result ~base_path ~keeper_name with
     | Ok None -> ()
     | Ok (Some _) -> Alcotest.fail "visible quarantine settlement retained binding"
     | Error detail ->
       Alcotest.failf "visible quarantine binding reload failed: %s" detail);
    match P.transition_outbox_result ~base_path ~keeper_name with
    | Ok [ { receipt = durable_receipt; _ } ] ->
      Alcotest.(check bool)
        "visible quarantine has exactly one durable settlement"
        true
        (receipt = durable_receipt);
      (match durable_receipt.settlement with
       | P.Settle_exact
           { outcome = P.Terminal cause
           ; slot_id = durable_slot
           ; call_id = durable_call
           ; _
           } ->
         Alcotest.(check bool)
           "visible quarantine settlement preserves cause and identity"
           true
           (cause = terminal.cause
            && String.equal durable_slot terminal.slot_id
            && String.equal durable_call terminal.call_id)
       | _ -> Alcotest.fail "visible quarantine lost exact terminal settlement")
    | Ok _ -> Alcotest.fail "visible quarantine produced multiple settlements"
    | Error detail -> Alcotest.failf "visible quarantine outbox reload failed: %s" detail
  in
  List.iter
    (fun (_label, run) -> run ())
    [ "bind", bind_visibility
    ; "release", release_visibility
    ; "quarantine", quarantine_visibility
    ]
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
            "order, generation, and call ids are immutable"
            `Quick
            test_preparation_freezes_order_generation_and_unique_call_ids
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
            "release failure blocks successor"
            `Quick
            test_release_failure_blocks_successor
        ; Alcotest.test_case
            "heartbeat guard binds before POST"
            `Quick
            test_heartbeat_guard_binds_before_post
        ; Alcotest.test_case
            "visible sync uncertainty seams fail closed"
            `Quick
            test_visible_sync_uncertainty_seams
        ] )
    ; ( "terminal ownership"
      , [ Alcotest.test_case
            "domain invalidity never reenters failover"
            `Quick
            test_domain_invalid_output_never_reenters_failover
        ; Alcotest.test_case
            "final OAS failure is generic terminal"
            `Quick
            test_final_oas_flow_failure_is_generic_source_terminal
        ; Alcotest.test_case
            "cancellation quarantines bound identity"
            `Quick
            test_cancellation_quarantines_only_bound_identity
        ; Alcotest.test_case
            "terminalization is canonical and durable"
            `Quick
            test_post_success_terminalization_is_canonical_and_durable
        ; Alcotest.test_case
            "terminalization overlap is affine and durable"
            `Quick
            test_post_success_terminalization_overlap_is_affine_and_durable
        ; Alcotest.test_case
            "terminalization failures preserve full binding"
            `Quick
            test_post_success_terminalization_failures_preserve_full_binding
        ] )
    ; ( "affinity and non-sharing"
      , [ Alcotest.test_case
            "independent flows do not share call identity"
            `Quick
            test_independent_preparations_do_not_share_call_identity
        ; Alcotest.test_case
            "same-flow loser mutates no queue"
            `Quick
            test_same_flow_concurrent_loser_mutates_no_queue
        ] )
    ]
;;
