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
  | C.Terminalization_owner_unregistered_deferred ->
    Alcotest.fail "current exact owner unexpectedly deferred terminalization"
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
  let prepared = prepare_exn ~keeper_name:"keeper-domain-invalid" ~registry () in
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

let test_two_keeper_scopes_freeze_and_do_not_share_preferences () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  with_temp_dir "masc-two-keeper-flow-scope"
  @@ fun base_path ->
  let keeper_a = "keeper-flow-scope-a" in
  let keeper_b = "keeper-flow-scope-b" in
  let slot_a = "two-keeper-slot-a" in
  let slot_b = "two-keeper-slot-b" in
  let server_a = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let server_b = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc two-keeper exact-flow scope"
      [ { id = slot_a; base_url = server_a.base_url }
      ; { id = slot_b; base_url = server_b.base_url }
      ]
  in
  let registry_a = publish_exn ~slot_ids:[ slot_a; slot_b ] snapshot in
  let prepared_a =
    prepare_exn
      ~base_path
      ~keeper_name:keeper_a
      ~registry:registry_a
      ()
  in
  let registry_b = publish_exn ~slot_ids:[ slot_b; slot_a ] snapshot in
  let prepared_b_before =
    prepare_exn
      ~base_path
      ~keeper_name:keeper_b
      ~registry:registry_b
      ()
  in
  let lease_a = claim_manual_lease ~base_path ~keeper_name:keeper_a in
  let guard_a =
    Keeper_heartbeat_loop.For_testing.exact_execution_guard
      ~base_path
      ~keeper_name:keeper_a
      ~lease:lease_a
  in
  let completed_a =
    execute_prepared_lane
      ~keeper_name:keeper_a
      ~net
      ~clock
      ~exact_execution_guard:guard_a
      prepared_a
    |> completed_exn
  in
  Keeper_registry.For_testing.unregister ~base_path keeper_b;
  ensure_registered_keeper ~base_path keeper_b;
  (match
     C.execute_prepared_lane
       ~keeper_name:keeper_b
       ~net
       ~clock
       prepared_b_before
   with
   | Error C.Exact_owner_unregistered_deferred -> ()
   | Error _ ->
     Alcotest.fail "stale owner generation returned the wrong typed failure"
   | Ok _ ->
     Alcotest.fail "stale owner generation crossed re-registration");
  Alcotest.(check int)
    "stale owner dispatched nothing"
    0
    (F.post_count server_b);
  let prepared_b_after =
    prepare_exn
      ~base_path
      ~keeper_name:keeper_b
      ~registry:registry_b
      ()
  in
  Alcotest.(check (list string))
    "keeper A freezes its declared snapshot"
    [ slot_a; slot_b ]
    (C.For_testing.candidate_snapshot_slot_ids prepared_a);
  Alcotest.(check (list string))
    "keeper B snapshot prepared before A success stays frozen"
    [ slot_b; slot_a ]
    (C.For_testing.candidate_snapshot_slot_ids prepared_b_before);
  Alcotest.(check (list string))
    "keeper A success cannot reorder keeper B future snapshot"
    [ slot_b; slot_a ]
    (C.For_testing.candidate_snapshot_slot_ids prepared_b_after);
  let lease_b = claim_manual_lease ~base_path ~keeper_name:keeper_b in
  let guard_b =
    Keeper_heartbeat_loop.For_testing.exact_execution_guard
      ~base_path
      ~keeper_name:keeper_b
      ~lease:lease_b
  in
  let completed_b =
    execute_prepared_lane
      ~keeper_name:keeper_b
      ~net
      ~clock
      ~exact_execution_guard:guard_b
      prepared_b_after
    |> completed_exn
  in
  let observation_a = C.completed_attempt_observation completed_a in
  let observation_b = C.completed_attempt_observation completed_b in
  Alcotest.(check string) "keeper A dispatches its frozen first slot" slot_a observation_a.slot_id;
  Alcotest.(check string) "keeper B dispatches its frozen first slot" slot_b observation_b.slot_id;
  Alcotest.(check bool)
    "keeper attempts do not share call identity"
    true
    (not (String.equal observation_a.call_id observation_b.call_id));
  Alcotest.(check int) "keeper A posts once" 1 (F.post_count server_a);
  Alcotest.(check int) "keeper B posts once" 1 (F.post_count server_b)
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
  let prepared = prepare_exn ~keeper_name ~registry () in
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
  let prepared = prepare_exn ~keeper_name ~registry () in
  let durable_guard =
    Keeper_heartbeat_loop.For_testing.exact_execution_guard
      ~base_path
      ~keeper_name
      ~lease
  in
  let guard : C.exact_execution_guard =
    { durable_guard with
      before_dispatch =
        (fun observation ->
           expected_observation := Some observation;
           durable_guard.before_dispatch observation)
    }
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

let test_post_success_restart_remains_at_most_once_and_fail_closed () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "masc-post-success-restart-at-most-once" @@ fun base_path ->
  let keeper_name = "restart-at-most-once" in
  let first_slot = "restart-first" in
  let successor_slot = "restart-successor" in
  let first =
    F.start_server ~sw ~net ~clock (F.Reply valid_response)
  in
  let successor =
    F.start_server ~sw ~net ~clock (F.Reply valid_response)
  in
  let snapshot =
    F.resolver_snapshot
      ~source:"post-success-restart-at-most-once"
      [ { id = first_slot; base_url = first.base_url }
      ; { id = successor_slot; base_url = successor.base_url }
      ]
  in
  let registry =
    publish_exn ~slot_ids:[ first_slot; successor_slot ] snapshot
  in
  let prepared = prepare_exn ~base_path ~keeper_name ~registry () in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  let guard =
    Keeper_heartbeat_loop.For_testing.exact_execution_guard
      ~base_path
      ~keeper_name
      ~lease
  in
  let observation =
    try
      let completed =
        execute_prepared_lane
          ~keeper_name
          ~net
          ~clock
          ~exact_execution_guard:guard
          prepared
        |> completed_exn
      in
      raise
        (Stop_after_oas_success
           (C.completed_attempt_observation completed))
    with
    | Stop_after_oas_success observation -> observation
  in
  Alcotest.(check int)
    "provider POST completed exactly once before restart"
    1
    (F.post_count first);
  Alcotest.(check int)
    "successor was not dispatched before restart"
    0
    (F.post_count successor);
  let binding_before =
    match P.exact_execution_binding_result ~base_path ~keeper_name with
    | Ok (Some ({ status = P.Dispatch_uncertain; _ } as binding)) ->
        binding
    | Ok (Some _) ->
        Alcotest.fail "post-success stop did not retain dispatch-uncertain binding"
    | Ok None ->
        Alcotest.fail "post-success stop lost exact execution binding"
    | Error detail ->
        Alcotest.failf "post-success binding load failed: %s" detail
  in
  Alcotest.(check string)
    "durable binding retains the OAS slot identity"
    observation.slot_id
    binding_before.slot_id;
  Alcotest.(check string)
    "durable binding retains the OAS call identity"
    observation.call_id
    binding_before.call_id;
  Alcotest.(check string)
    "durable binding retains the OAS plan identity"
    observation.receipt_plan_fingerprint
    binding_before.plan_fingerprint;
  Alcotest.(check string)
    "durable binding retains the OAS request identity"
    observation.receipt_request_body_sha256
    binding_before.request_body_sha256;
  Alcotest.(check string)
    "durable binding retains the source lease"
    lease.lease_id
    binding_before.lease_id;
  Alcotest.(check int64)
    "durable binding retains the source lease sequence"
    lease.sequence
    binding_before.lease_sequence;
  let state_before_probe =
    match P.load_state_result ~base_path ~keeper_name with
    | Ok state -> state
    | Error detail ->
        Alcotest.failf "pre-recovery state load failed: %s" detail
  in
  Alcotest.(check bool)
    "post-success stop creates no pending successor"
    true
    (Q.is_empty (State.pending state_before_probe));
  let pending_successor : Q.stimulus =
    { post_id = "post-success-restart-fence-probe"
    ; urgency = Q.Immediate
    ; arrived_at = 2.5
    ; payload = Q.Manual_compaction_requested
    }
  in
  let check_only_probe_pending label state =
    match Q.to_list (State.pending state) with
    | [ pending ] ->
      Alcotest.(check string)
        (label ^ " identity")
        pending_successor.post_id
        pending.post_id
    | pending ->
      Alcotest.failf
        "%s count: expected one pending probe, got %d"
        label
        (List.length pending)
  in
  (match
     P.update_checked_result
       ~base_path
       ~keeper_name
       (fun pending -> Ok (Q.enqueue pending pending_successor))
   with
   | Ok () -> ()
   | Error detail ->
       Alcotest.failf "pending successor probe persist failed: %s" detail);
  (match
     Recovery.prepare_registration_result
       ~base_path
       ~keeper_name
       ~settled_at:3.0
   with
   | Error _ -> ()
   | Ok _ ->
       Alcotest.fail
         "fresh runtime admitted a dispatch-uncertain exact execution");
  let recovered =
    match P.load_state_result ~base_path ~keeper_name with
    | Ok state -> state
    | Error detail ->
        Alcotest.failf "fresh state reload failed: %s" detail
  in
  Alcotest.(check bool)
    "durable opaque binding identity is unchanged"
    true
    (State.exact_execution_binding recovered = Some binding_before);
  check_only_probe_pending
    "restart adds no pending beyond the probe"
    recovered;
  Alcotest.(check int)
    "restart creates no requeue transition"
    0
    (List.length (State.transition_outbox recovered));
  Alcotest.(check bool)
    "restart retains the complete original active lease"
    true
    (State.active_lease recovered = Some lease);
  (match
     P.claim_when_result
       ~base_path
       ~keeper_name
       ~claimed_at:4.0
       ~ready:(fun _ -> true)
       ()
   with
   | Ok None -> ()
   | Ok (Some _) ->
       Alcotest.fail "post-recovery scheduling claimed a successor"
   | Error detail ->
       Alcotest.failf "post-recovery scheduling boundary failed: %s" detail);
  let after_claim =
    match P.load_state_result ~base_path ~keeper_name with
    | Ok state -> state
    | Error detail ->
        Alcotest.failf "post-claim state reload failed: %s" detail
  in
  check_only_probe_pending
    "fenced successor remains pending after scheduling"
    after_claim;
  Alcotest.(check int)
    "provider POST remains exactly once after restart"
    1
    (F.post_count first);
  Alcotest.(check int)
    "restart does not dispatch the successor"
    0
    (F.post_count successor)

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
  let prepared = prepare_exn ~keeper_name ~registry () in
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
    |> terminalized_exn
  in
  let replay =
    C.terminalize_post_success
      terminalizer
      Keeper_event_queue_state.Checkpoint_persistence_failed
    |> terminalized_exn
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
   | C.Commit_claim_rejected _
   | C.Commit_claim_owner_unregistered_deferred ->
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
    | C.Terminalization_invariant_failed _
    | C.Terminalization_owner_unregistered_deferred ->
      Alcotest.fail "reject crossed an installed commit claim"
  in
  let pending = C.For_testing.post_success_snapshot terminalizer in
  Alcotest.(check bool)
    "installed checkpoint remains pending valid"
    true
    (pending.phase = C.Phase_installed_pending_valid);
  Alcotest.(check int) "reject settlement has not run" 0 pending.domain_rejected_attempts;
  Alcotest.(check int) "quarantine has not run" 0 !quarantine_calls;
  let settlement_entered, resolve_settlement_entered =
    Eio.Promise.create ()
  in
  let release_settlement, resolve_release_settlement =
    Eio.Promise.create ()
  in
  let waiter_joined, resolve_waiter_joined = Eio.Promise.create () in
  let first_result, resolve_first_result = Eio.Promise.create () in
  let second_result, resolve_second_result = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    C.For_testing.settle_post_success_domain_valid_with
      ~settle:(fun () ->
        Eio.Promise.resolve resolve_settlement_entered ();
        Eio.Promise.await release_settlement;
        Ok ())
      terminalizer
    |> Eio.Promise.resolve resolve_first_result);
  Eio.Promise.await settlement_entered;
  Eio.Fiber.fork ~sw (fun () ->
    C.For_testing.settle_post_success_domain_valid_with_wait_hook
      ~on_wait:(fun () -> Eio.Promise.resolve resolve_waiter_joined ())
      terminalizer
    |> Eio.Promise.resolve resolve_second_result);
  Eio.Promise.await waiter_joined;
  Eio.Promise.resolve resolve_release_settlement ();
  (match Eio.Promise.await first_result with
   | Ok () -> ()
   | Error detail ->
     Alcotest.failf "first Domain_valid settlement failed: %s" detail);
  (match Eio.Promise.await second_result with
   | Ok () -> ()
   | Error detail ->
     Alcotest.failf "joined Domain_valid settlement diverged: %s" detail);
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
   | C.Terminalization_invariant_failed _
   | C.Terminalization_owner_unregistered_deferred ->
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
  let prepared = prepare_exn ~keeper_name ~registry () in
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
  let checkpoint_calls = ref 0 in
  Eio.Fiber.fork ~sw (fun () ->
    C.terminalize_post_success
      terminalizer
      Keeper_event_queue_state.Invalid_structural_evidence
    |> terminalized_exn
    |> Eio.Promise.resolve resolve_first_result);
  Eio.Promise.await quarantine_entered;
  let commit_waiter =
    match C.claim_post_success_commit terminalizer with
    | C.Commit_claim_in_progress waiter -> waiter
    | C.Commit_claim_acquired ->
      incr checkpoint_calls;
      Alcotest.fail "commit acquired after reject claim"
    | C.Commit_claim_already_committed
    | C.Commit_claim_rejected _
    | C.Commit_claim_owner_unregistered_deferred ->
      Alcotest.fail "reject claimant did not block concurrent commit"
  in
  let claimed = C.For_testing.post_success_snapshot terminalizer in
  Alcotest.(check bool)
    "reject claim is visible at the quarantine barrier"
    true
    (claimed.phase = C.Phase_reject_claimed);
  Alcotest.(check int) "reject settlement claimed once" 1 claimed.domain_rejected_attempts;
  Alcotest.(check int) "valid settlement not attempted" 0 claimed.domain_valid_attempts;
  Alcotest.(check int) "blocked commit performs no checkpoint I/O" 0 !checkpoint_calls;
  Eio.Promise.resolve resolve_release_quarantine ();
  let first = Eio.Promise.await first_result in
  Eio.Promise.await commit_waiter;
  (match C.claim_post_success_commit terminalizer with
   | C.Commit_claim_rejected (terminal, Ok ()) when terminal = first -> ()
   | C.Commit_claim_rejected (_, Error detail) ->
     Alcotest.failf "canonical rejection failed: %s" detail
   | C.Commit_claim_acquired
   | C.Commit_claim_in_progress _
   | C.Commit_claim_already_committed
   | C.Commit_claim_rejected _
   | C.Commit_claim_owner_unregistered_deferred ->
     Alcotest.fail "commit did not observe the canonical rejected disposition");
  Alcotest.(check int) "overlap performs one quarantine" 1 !quarantine_calls;
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
       ~terminal:first
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
  match P.load_state_result ~base_path ~keeper_name with
  | Ok state
    when List.length (Keeper_event_queue_state.transition_outbox state) = 1 ->
    ()
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
       let prepared = prepare_exn ~keeper_name ~registry () in
       let durable_guard =
         Keeper_heartbeat_loop.For_testing.exact_execution_guard
           ~base_path
           ~keeper_name
           ~lease
       in
       let quarantine_calls = ref 0 in
       let quarantine_causes = ref [] in
       let guard : C.exact_execution_guard =
         { durable_guard with
           quarantine =
             (fun cause observation ->
                incr quarantine_calls;
                quarantine_causes := cause :: !quarantine_causes;
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
       let persistence_failure_exn = function
         | C.Terminalization_persistence_failed (terminal, detail) ->
           terminal, detail
         | C.Terminalized _
         | C.Terminalization_commit_in_progress _
         | C.Terminalization_already_committed
         | C.Terminalization_invariant_failed _
         | C.Terminalization_owner_unregistered_deferred ->
           Alcotest.fail
             "quarantine persistence failure was not surfaced as typed uncertainty"
       in
       let first =
         C.terminalize_post_success
           terminalizer
           Keeper_event_queue_state.Invalid_structural_evidence
         |> persistence_failure_exn
       in
       let replay =
         C.terminalize_post_success
           terminalizer
           Keeper_event_queue_state.Checkpoint_persistence_failed
         |> persistence_failure_exn
       in
       Alcotest.(check int) (label ^ " quarantine runs once") 1 !quarantine_calls;
       Alcotest.(check string)
         (label ^ " replay returns canonical failure")
         (snd first)
         (snd replay);
       Alcotest.(check bool)
         (label ^ " replay returns canonical terminal")
         true
         (fst first = fst replay);
       Alcotest.(check bool)
         (label ^ " first cause remains canonical")
         true
         ((fst first).cause
          = Keeper_event_queue_state.Invalid_structural_evidence);
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
    let prepared = prepare_exn ~keeper_name ~registry () in
    let observed = ref None in
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
             observed := Some candidate;
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
    let observation = captured_observation_exn "visible bind" !observed in
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
    let prepared = prepare_exn ~keeper_name ~registry () in
    let first_observation = ref None in
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
             if String.equal candidate.slot_id first_slot
             then first_observation := Some candidate;
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
    let first_observation =
      captured_observation_exn "visible release" !first_observation
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
    let prepared = prepare_exn ~keeper_name ~registry () in
    let observed = ref None in
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
             observed := Some candidate;
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
    let observation =
      captured_observation_exn "visible quarantine" !observed
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
    match P.load_state_result ~base_path ~keeper_name with
    | Ok state ->
      (match Keeper_event_queue_state.transition_outbox state with
       | [ { receipt = durable_receipt; _ } ] ->
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
       | _ -> Alcotest.fail "visible quarantine produced multiple settlements")
    | Error detail -> Alcotest.failf "visible quarantine outbox reload failed: %s" detail
  in
  List.iter
    (fun (_label, run) -> run ())
    [ "bind", bind_visibility
    ; "release", release_visibility
    ; "quarantine", quarantine_visibility
    ]
;;

let test_post_success_owner_replacement_defers_success_projection () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let keeper_name = "keeper-post-success-owner-replaced" in
  let slot_id = "post-success-owner-replaced" in
  let replace_owner = ref (fun () -> ()) in
  let server =
    F.start_server
      ~on_request_before_reply:(fun () -> !replace_owner ())
      ~sw
      ~net
      ~clock
      (F.Reply valid_response)
  in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc post-success owner replacement"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name ~registry () in
  let old_entry =
    match Keeper_registry.get ~base_path:exact_flow_base_path keeper_name with
    | Some entry -> entry
    | None -> Alcotest.fail "prepared compaction owner disappeared"
  in
  replace_owner :=
    (fun () ->
       (match Keeper_registry.unregister_exact old_entry with
        | Keeper_registry.Exact_unregistered -> ()
        | _ -> Alcotest.fail "compaction owner was not replaced during POST");
       ensure_registered_keeper ~base_path:exact_flow_base_path keeper_name);
  let bind_calls = ref 0 in
  let release_calls = ref 0 in
  let quarantine_calls = ref 0 in
  let guard : C.exact_execution_guard =
    { before_dispatch =
        (fun _ ->
           incr bind_calls;
           Ok C.Fsync_completed)
    ; release_before_dispatch =
        (fun _ ->
           incr release_calls;
           Ok C.Fsync_completed)
    ; quarantine =
        (fun _ _ ->
           incr quarantine_calls;
           Ok C.Fsync_completed)
    }
  in
  (match
    execute_prepared_lane
      ~keeper_name
      ~net
      ~clock
      ~exact_execution_guard:guard
      prepared
   with
   | Error C.Exact_owner_unregistered_deferred -> ()
   | Error _ -> Alcotest.fail "POST replacement returned the wrong terminal"
   | Ok _ -> Alcotest.fail "replaced compaction owner retained stale success");
  (match
     execute_prepared_lane
       ~keeper_name
       ~net
       ~clock
       ~exact_execution_guard:guard
       prepared
   with
   | Error C.Exact_owner_unregistered_deferred -> ()
   | Error _ -> Alcotest.fail "stale retry returned the wrong terminal"
   | Ok _ -> Alcotest.fail "stale retry projected a completed plan");
  Alcotest.(check int)
    "real compaction POST crossed replacement exactly once"
    1
    (F.post_count server);
  Alcotest.(check int) "replacement binds one exact identity" 1 !bind_calls;
  Alcotest.(check int) "replacement releases no stale identity" 0 !release_calls;
  Alcotest.(check int)
    "replacement quarantines no stale success"
    0
    !quarantine_calls
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
        ; Alcotest.test_case
            "heartbeat guard binds before POST"
            `Quick
            test_heartbeat_guard_binds_before_post
        ; Alcotest.test_case
            "post-success restart stays fenced at most once"
            `Quick
            test_post_success_restart_remains_at_most_once_and_fail_closed
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
            "cancellation preserves lifecycle-authorized identity"
            `Quick
            test_cancellation_preserves_lifecycle_authorized_identity
        ; Alcotest.test_case
            "terminalization is canonical and durable"
            `Quick
            test_post_success_terminalization_is_canonical_and_durable
        ; Alcotest.test_case
            "commit claim blocks reject after install"
            `Quick
            test_post_success_commit_claim_blocks_reject
        ; Alcotest.test_case
            "terminalization overlap is affine and durable"
            `Quick
            test_post_success_terminalization_overlap_is_affine_and_durable
        ; Alcotest.test_case
            "terminalization failures preserve full binding"
            `Quick
            test_post_success_terminalization_failures_preserve_full_binding
        ; Alcotest.test_case
            "owner replacement during POST defers success projection"
            `Quick
            test_post_success_owner_replacement_defers_success_projection
        ] )
    ; ( "affinity and non-sharing"
      , [ Alcotest.test_case
            "same-flow loser mutates no queue"
            `Quick
            test_same_flow_concurrent_loser_mutates_no_queue
        ; Alcotest.test_case
            "two keepers freeze and isolate future preferences"
            `Quick
            test_two_keeper_scopes_freeze_and_do_not_share_preferences
        ] )
    ]
;;
