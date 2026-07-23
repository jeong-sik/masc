(** Composition-level conformance for the MASC compaction exact-output lane.

    These tests use real OAS resolver snapshots, ready plans, receipts, and
    local HTTP effects. They intentionally do not repeat provider codec or
    resolver validation coverage owned by OAS. *)

open Masc
module C = Keeper_compaction_llm_summarizer
module EO = Agent_sdk.Exact_output
module Registry = Runtime_exact_output_registry
module S = Keeper_structured_output_schema
module T = Agent_sdk.Types
module U = Keeper_compaction_unit
module F = Compaction_exact_output_fixture
module P = Keeper_event_queue_persistence
module Q = Keeper_event_queue

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

let permissive_exact_execution_guard : C.exact_execution_guard =
  { before_dispatch = (fun _ -> Ok C.Durable)
  ; release_before_dispatch = (fun _ -> Ok C.Durable)
  ; quarantine = (fun _ _ -> Ok C.Durable)
  }
;;

let execute_prepared_lane
      ~keeper_name
      ~net
      ?clock
      ?(exact_execution_guard = permissive_exact_execution_guard)
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
  | Error _ -> Alcotest.fail "compaction lane preparation failed"
;;

let completed_exn = function
  | Ok completed -> completed
  | Error _ -> Alcotest.fail "compaction lane execution failed"
;;

let observation_exn prepared slot_id =
  C.For_testing.attempt_observations prepared
  |> List.find_opt (fun (observation : C.attempt_observation) ->
    String.equal observation.slot_id slot_id)
  |> function
  | Some observation -> observation
  | None -> Alcotest.failf "missing retained receipt observation for %s" slot_id
;;

let check_observation
      ~label
      ~phase
      ~dispatch_count
      ?catalog_generation_fingerprint
      observation
  =
  Alcotest.(check bool)
    (label ^ " call id retained")
    true
    (String.trim observation.C.call_id <> "");
  Alcotest.(check bool)
    (label ^ " receipt plan fingerprint retained")
    true
    (String.trim observation.receipt_plan_fingerprint <> "");
  Alcotest.(check bool)
    (label ^ " receipt request hash retained")
    true
    (String.trim observation.receipt_request_body_sha256 <> "");
  Alcotest.(check bool)
    (label ^ " phase")
    true
    (observation.C.phase = phase);
  Alcotest.(check int)
    (label ^ " dispatch count")
    dispatch_count
    observation.dispatch_count;
  Option.iter
    (fun expected ->
      Alcotest.(check string)
        (label ^ " catalog generation")
        expected
        observation.catalog_generation_fingerprint)
    catalog_generation_fingerprint
;;

let test_missing_compaction_lane_is_explicit_degraded_state () =
  let snapshot =
    F.resolver_snapshot
      ~source:"masc missing compaction lane"
      [ { id = "configured-slot"; base_url = "http://127.0.0.1:9" } ]
  in
  let registry =
    match Runtime_exact_output_registry.publish ~lanes:[] snapshot with
    | Ok registry -> registry
    | Error error ->
      Alcotest.failf
        "empty exact-output registry must publish: %s"
        (Runtime_exact_output_registry.publication_error_to_string error)
  in
  match
    C.prepare_lane
      ~keeper_name:"keeper-missing-compaction-lane"
      ~registry
      ~lane_id:"compaction_exact"
      ~units
  with
  | Error C.Exact_lane_unconfigured -> ()
  | Error _ -> Alcotest.fail "missing compaction lane returned the wrong typed failure"
  | Ok _ -> Alcotest.fail "missing compaction lane must not be synthesized"
;;

let test_missing_credential_is_deferred_past_registry_admission () =
  let slot_id = "credential-gated-slot" in
  let snapshot =
    F.resolver_snapshot
      ~api_key_env:"MASC_TEST_EXACT_OUTPUT_MISSING_CREDENTIAL"
      ~source:"masc credential-free admission"
      [ { id = slot_id; base_url = "http://127.0.0.1:9" } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  (match Registry.resolve_lane registry ~lane_id:conformance_lane_id with
   | Error
       (Registry.No_usable_lane_slots
          { unavailable_slots =
              [ { cause = EO.Missing_target_credential { environment_variable; _ }
                ; _
                }
              ]
          ; _
          }) ->
     Alcotest.(check string)
       "missing credential cause remains typed"
       "MASC_TEST_EXACT_OUTPUT_MISSING_CREDENTIAL"
       environment_variable
   | Ok _ -> Alcotest.fail "missing credential must fail target selection"
   | Error _ ->
     Alcotest.fail "missing credential returned the wrong lane-resolution failure");
  match
    C.prepare_lane
      ~keeper_name:"keeper-missing-credential"
      ~registry
      ~lane_id:conformance_lane_id
      ~units
  with
  | Error C.Exact_target_selection_failed -> ()
  | Error _ -> Alcotest.fail "missing credential returned the wrong typed failure"
  | Ok _ -> Alcotest.fail "missing credential must not produce a ready plan"
;;

let test_unknown_target_is_rejected_by_registry_publication () =
  let unknown_target = "unknown-exact-target" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc unknown-target admission"
      [ { id = "configured-target"; base_url = "http://127.0.0.1:9" } ]
  in
  let lanes : Runtime_schema.exact_output_lane_decl list =
    [ { id = conformance_lane_id; slot_ids = [ unknown_target ] } ]
  in
  match Registry.publish ~lanes snapshot with
  | Error (Registry.Unknown_lane_slot { target_ref; _ }) ->
    Alcotest.(check string) "unknown target identity" unknown_target target_ref
  | Error _ -> Alcotest.fail "unknown target returned the wrong publication failure"
  | Ok _ -> Alcotest.fail "unknown target must not publish in the MASC registry"
;;

let check_failure label expected = function
  | Error actual when actual = expected -> ()
  | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label
  | Error _ -> Alcotest.failf "%s returned the wrong failure class" label
;;

let test_unavailable_slots_are_skipped_in_both_orders () =
  let check unavailable_first =
    run_eio
    @@ fun ~sw ~net ~clock ->
    let usable = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
    let unavailable_id =
      if unavailable_first then "unavailable-first" else "unavailable-last"
    in
    let usable_id = if unavailable_first then "usable-last" else "usable-first" in
    let fixtures : F.target_fixture list =
      [ { id = unavailable_id; base_url = "http://127.0.0.1:9" }
      ; { id = usable_id; base_url = usable.base_url }
      ]
    in
    let snapshot =
      F.resolver_snapshot
        ~api_key_envs:
          [ unavailable_id, "MASC_TEST_EXACT_OUTPUT_UNAVAILABLE_MIXED" ]
        ~source:"masc mixed availability"
        fixtures
    in
    let slot_ids =
      if unavailable_first
      then [ unavailable_id; usable_id ]
      else [ usable_id; unavailable_id ]
    in
    let registry = publish_exn ~slot_ids snapshot in
    let expected_unavailable_position = if unavailable_first then 1 else 2 in
    (match Registry.resolve_lane registry ~lane_id:conformance_lane_id with
     | Ok
         { selected_slots = [ selected ]
         ; unavailable_slots = [ unavailable ]
         } ->
       Alcotest.(check string) "usable slot retained" usable_id selected.slot_id;
       Alcotest.(check string)
         "unavailable slot retained as diagnostics"
         unavailable_id
         unavailable.slot_id;
       Alcotest.(check int)
         "unavailable declaration position"
         expected_unavailable_position
         unavailable.position
     | Ok _ -> Alcotest.fail "mixed lane returned the wrong partition"
     | Error _ -> Alcotest.fail "mixed lane must retain its usable slot");
    let prepared = prepare_exn ~keeper_name:"keeper-mixed" ~registry in
    Alcotest.(check (list string))
      "only usable slot is prepared"
      [ usable_id ]
      (C.For_testing.admitted_slot_ids prepared);
    ignore
      (execute_prepared_lane
         ~keeper_name:"keeper-mixed"
         ~net
         ~clock
         prepared
       |> completed_exn
        : C.completed_plan);
    Alcotest.(check int) "usable slot dispatched once" 1 (F.post_count usable)
  in
  check true;
  check false
;;

let test_all_unavailable_slots_are_typed () =
  let first_id = "all-unavailable-first" in
  let second_id = "all-unavailable-second" in
  let snapshot =
    F.resolver_snapshot
      ~api_key_envs:
        [ first_id, "MASC_TEST_EXACT_OUTPUT_MISSING_FIRST"
        ; second_id, "MASC_TEST_EXACT_OUTPUT_MISSING_SECOND"
        ]
      ~source:"masc all unavailable"
      [ { id = first_id; base_url = "http://127.0.0.1:9" }
      ; { id = second_id; base_url = "http://127.0.0.1:9" }
      ]
  in
  let registry = publish_exn ~slot_ids:[ first_id; second_id ] snapshot in
  (match Registry.resolve_lane registry ~lane_id:conformance_lane_id with
   | Error
       (Registry.No_usable_lane_slots
          { unavailable_slots = [ first; second ]; _ }) ->
     Alcotest.(check string) "first unavailable slot" first_id first.slot_id;
     Alcotest.(check string) "second unavailable slot" second_id second.slot_id
   | Error _ -> Alcotest.fail "all-unavailable lane returned the wrong typed error"
   | Ok _ -> Alcotest.fail "all-unavailable lane must not resolve");
  match
    C.prepare_lane
      ~keeper_name:"keeper-all-unavailable"
      ~registry
      ~lane_id:conformance_lane_id
      ~units
  with
  | Error C.Exact_target_selection_failed -> ()
  | Error _ -> Alcotest.fail "all-unavailable preparation returned the wrong error"
  | Ok _ -> Alcotest.fail "all-unavailable preparation must fail"
;;

let test_preparation_is_ordered_effect_free_and_single_generation () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let first = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let second = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let fixtures : F.target_fixture list =
    [ { id = "prepare-first"; base_url = first.base_url }
    ; { id = "prepare-second"; base_url = second.base_url }
    ]
  in
  let snapshot = F.resolver_snapshot ~source:"masc preparation conformance" fixtures in
  let generation = F.catalog_generation_fingerprint snapshot in
  let registry = publish_exn ~slot_ids:[ "prepare-first"; "prepare-second" ] snapshot in
  let prepared =
    prepare_exn
      ~keeper_name:"keeper-preparation"
      ~registry
  in
  Alcotest.(check (list string))
    "declaration order is retained"
    [ "prepare-first"; "prepare-second" ]
    (C.For_testing.admitted_slot_ids prepared);
  Alcotest.(check int) "first target has no preparation effect" 0 (F.post_count first);
  Alcotest.(check int) "second target has no preparation effect" 0 (F.post_count second);
  let first_observations = C.For_testing.attempt_observations prepared in
  let second_observations = C.For_testing.attempt_observations prepared in
  List.iter2
    (fun first second ->
       Alcotest.(check string)
         "preparation retains one stable call id per slot"
         first.C.call_id
         second.C.call_id)
    first_observations
    second_observations;
  List.iter
    (fun slot_id ->
      check_observation
        ~label:slot_id
        ~phase:EO.Not_started
        ~dispatch_count:0
        ~catalog_generation_fingerprint:generation
        (observation_exn prepared slot_id))
    [ "prepare-first"; "prepare-second" ]
;;

let test_published_snapshot_replacement_cannot_mix_prepared_lane () =
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
  let prepared =
    prepare_exn
      ~keeper_name:"keeper-frozen-a"
      ~registry:registry_a
  in
  let snapshot_b =
    F.resolver_snapshot
      ~source:"masc frozen registry B"
      [ { id = "replacement-slot"; base_url = server_b.base_url } ]
  in
  let registry_b = publish_exn ~slot_ids:[ "replacement-slot" ] snapshot_b in
  let prepared_b =
    prepare_exn ~keeper_name:"keeper-frozen-b" ~registry:registry_b
  in
  Alcotest.(check bool)
    "MASC publication generation advances atomically"
    true
    (Int64.compare
       (Runtime_exact_output_registry.generation registry_a)
       (Runtime_exact_output_registry.generation registry_b)
     < 0);
  Alcotest.(check (list string))
    "replacement publication carries its own lane declaration"
    [ "replacement-slot" ]
    (C.For_testing.admitted_slot_ids prepared_b);
  let completed =
    execute_prepared_lane
      ~keeper_name:"keeper-frozen-a"
      ~net
      ~clock
      prepared
    |> completed_exn
  in
  let evidence = C.completed_exact_execution_evidence completed in
  let generation_a = F.catalog_generation_fingerprint snapshot_a in
  let generation_b = F.catalog_generation_fingerprint snapshot_b in
  Alcotest.(check bool)
    "resolver snapshots have distinct OAS generations"
    true
    (not (String.equal generation_a generation_b));
  Alcotest.(check string)
    "execution retains prepared snapshot generation"
    generation_a
    (C.exact_execution_evidence_catalog_generation_fingerprint evidence);
  Alcotest.(check int) "prepared A dispatches to A" 1 (F.post_count server_a);
  Alcotest.(check int) "later publication B is not observed" 0 (F.post_count server_b)
;;

let test_before_dispatch_zero_advances_exactly_once () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let first = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let second = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let third = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~connect_timeouts:[ "before-dispatch", 1.0 ]
      ~source:"masc before-dispatch failover"
      [ { id = "before-dispatch"; base_url = first.base_url }
      ; { id = "after-before-dispatch"; base_url = second.base_url }
      ; { id = "must-remain-ready"; base_url = third.base_url }
      ]
  in
  let registry =
    publish_exn
      ~slot_ids:
        [ "before-dispatch"; "after-before-dispatch"; "must-remain-ready" ]
      snapshot
  in
  let prepared =
    prepare_exn
      ~keeper_name:"keeper-before-dispatch"
      ~registry
  in
  ignore
    (execute_prepared_lane
       ~keeper_name:"keeper-before-dispatch"
       ~net
       prepared
     |> completed_exn
     : C.completed_plan);
  check_observation
    ~label:"rejected transport"
    ~phase:EO.Before_dispatch
    ~dispatch_count:0
    (observation_exn prepared "before-dispatch");
  check_observation
    ~label:"single successor"
    ~phase:EO.Terminal
    ~dispatch_count:1
    (observation_exn prepared "after-before-dispatch");
  check_observation
    ~label:"slot after success"
    ~phase:EO.Not_started
    ~dispatch_count:0
    (observation_exn prepared "must-remain-ready");
  Alcotest.(check int) "pre-dispatch target has no POST" 0 (F.post_count first);
  Alcotest.(check int) "one successor POST" 1 (F.post_count second);
  Alcotest.(check int) "no POST after successor success" 0 (F.post_count third)
;;

let test_visible_release_uncertainty_is_source_bound_terminal () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let first = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let second = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let first_slot = "visible-release-original" in
  let second_slot = "visible-release-forbidden-successor" in
  let snapshot =
    F.resolver_snapshot
      ~connect_timeouts:[ first_slot, 1.0 ]
      ~source:"masc visible release terminal"
      [ { id = first_slot; base_url = first.base_url }
      ; { id = second_slot; base_url = second.base_url }
      ]
  in
  let registry = publish_exn ~slot_ids:[ first_slot; second_slot ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-visible-release" ~registry in
  let release_calls = ref [] in
  let guard : C.exact_execution_guard =
    { before_dispatch = (fun _ -> Ok C.Durable)
    ; release_before_dispatch =
        (fun observation ->
           release_calls := observation :: !release_calls;
           Ok (C.Visible_durability_unknown "injected release after-rename failure"))
    ; quarantine = (fun _ _ -> Alcotest.fail "quarantine must not run")
    }
  in
  let terminal : P.exact_execution_terminal =
    match
      execute_prepared_lane
        ~keeper_name:"keeper-visible-release"
        ~net
        ~clock
        ~exact_execution_guard:guard
        prepared
    with
    | Error (C.Exact_execution_terminal terminal) -> terminal
    | Error _ -> Alcotest.fail "visible release returned the wrong typed failure"
    | Ok _ -> Alcotest.fail "visible release uncertainty incorrectly failed over"
  in
  let original = observation_exn prepared first_slot in
  Alcotest.(check bool)
    "visible release uses persistence terminal cause"
    true
    (terminal.cause = Keeper_event_queue_state.Terminal_persistence_failed);
  Alcotest.(check string) "visible release retains slot" original.slot_id terminal.slot_id;
  Alcotest.(check string) "visible release retains call" original.call_id terminal.call_id;
  (match !release_calls with
   | [ released ] ->
     Alcotest.(check string) "release called for original slot" first_slot released.slot_id
   | _ -> Alcotest.fail "visible release was not called exactly once");
  Alcotest.(check int) "visible release original has no POST" 0 (F.post_count first);
  Alcotest.(check int)
    "visible release never dispatches successor"
    0
    (F.post_count second)
;;

let test_post_dispatch_failure_is_terminal () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let first = F.start_server ~sw ~net ~clock F.Abort_after_request in
  let second = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc post-dispatch terminal"
      [ { id = "post-dispatch"; base_url = first.base_url }
      ; { id = "forbidden-post-dispatch-failover"; base_url = second.base_url }
      ]
  in
  let registry =
    publish_exn
      ~slot_ids:[ "post-dispatch"; "forbidden-post-dispatch-failover" ]
      snapshot
  in
  let prepared =
    prepare_exn
      ~keeper_name:"keeper-post-dispatch"
      ~registry
  in
  (match execute_prepared_lane ~keeper_name:"keeper-post-dispatch" ~net prepared with
   | Error (C.Exact_execution_failed_after_dispatch observation) ->
     Alcotest.(check string)
       "post-dispatch failure retains slot"
       "post-dispatch"
       observation.slot_id;
     Alcotest.(check bool)
       "post-dispatch failure retains call id"
       true
       (String.trim observation.call_id <> "")
   | Error _ -> Alcotest.fail "post-dispatch failure returned the wrong class"
   | Ok _ -> Alcotest.fail "post-dispatch failure unexpectedly succeeded");
  check_observation
    ~label:"post-dispatch failure"
    ~phase:EO.Dispatch_started
    ~dispatch_count:1
    (observation_exn prepared "post-dispatch");
  check_observation
    ~label:"forbidden successor"
    ~phase:EO.Not_started
    ~dispatch_count:0
    (observation_exn prepared "forbidden-post-dispatch-failover");
  Alcotest.(check int) "failed request dispatched once" 1 (F.post_count first);
  Alcotest.(check int) "post-dispatch failure does not fail over" 0 (F.post_count second)
;;

let test_domain_invalid_json_is_terminal () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let first = F.start_server ~sw ~net ~clock (F.Reply domain_invalid_response) in
  let second = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc domain-invalid terminal"
      [ { id = "domain-invalid"; base_url = first.base_url }
      ; { id = "forbidden-domain-failover"; base_url = second.base_url }
      ]
  in
  let registry =
    publish_exn
      ~slot_ids:[ "domain-invalid"; "forbidden-domain-failover" ]
      snapshot
  in
  let prepared =
    prepare_exn
      ~keeper_name:"keeper-domain-invalid"
      ~registry
  in
  (match execute_prepared_lane ~keeper_name:"keeper-domain-invalid" ~net prepared with
   | Error (C.Invalid_plan_after_dispatch observation) ->
     Alcotest.(check string)
       "domain-invalid output retains slot"
       "domain-invalid"
       observation.slot_id;
     Alcotest.(check bool)
       "domain-invalid output retains call id"
       true
       (String.trim observation.call_id <> "")
   | Error _ -> Alcotest.fail "domain-invalid output returned the wrong class"
   | Ok _ -> Alcotest.fail "domain-invalid output unexpectedly succeeded");
  check_observation
    ~label:"domain-invalid response"
    ~phase:EO.Terminal
    ~dispatch_count:1
    (observation_exn prepared "domain-invalid");
  check_observation
    ~label:"domain successor"
    ~phase:EO.Not_started
    ~dispatch_count:0
    (observation_exn prepared "forbidden-domain-failover");
  Alcotest.(check int) "domain-invalid target dispatched once" 1 (F.post_count first);
  Alcotest.(check int) "domain invalidity does not fail over" 0 (F.post_count second)
;;

let test_post_dispatch_cancellation_is_typed_terminal () =
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
  let second = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc cancellation terminal"
      [ { id = "cancelled-dispatch"; base_url = first.base_url }
      ; { id = "forbidden-cancel-failover"; base_url = second.base_url }
      ]
  in
  let registry =
    publish_exn
      ~slot_ids:[ "cancelled-dispatch"; "forbidden-cancel-failover" ]
      snapshot
  in
  let prepared =
    prepare_exn
      ~keeper_name:"keeper-cancelled"
      ~registry
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
          prepared))
  in
  let retained_call_id =
    (observation_exn prepared "cancelled-dispatch").call_id
  in
  let cancellation_result =
    try
      Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        let context = Eio.Promise.await cancel_context in
        F.await_first_request first;
        Eio.Cancel.cancel context Cancel_after_request_arrived;
        Eio.Promise.await_exn execution)
    with
    | Eio.Time.Timeout ->
      Alcotest.fail "request-arrival cancellation watchdog expired"
  in
  (match cancellation_result with
   | Error (C.Exact_execution_cancelled_after_dispatch terminal) ->
     Alcotest.(check string)
       "terminal cancellation retains slot"
       "cancelled-dispatch"
       terminal.slot_id;
     Alcotest.(check string)
       "terminal cancellation retains OAS call id"
       retained_call_id
       terminal.call_id;
     Alcotest.(check bool)
       "terminal cancellation records dispatched phase"
       true
       (terminal.phase = EO.Dispatch_started);
     Alcotest.(check int)
       "terminal cancellation records one dispatch"
       1
       terminal.dispatch_count
   | Error _ -> Alcotest.fail "post-dispatch cancellation returned the wrong error"
   | Ok _ -> Alcotest.fail "post-dispatch cancellation unexpectedly succeeded");
  check_observation
    ~label:"cancelled real receipt"
    ~phase:EO.Dispatch_started
    ~dispatch_count:1
    (observation_exn prepared "cancelled-dispatch");
  check_observation
    ~label:"cancel successor"
    ~phase:EO.Not_started
    ~dispatch_count:0
    (observation_exn prepared "forbidden-cancel-failover");
  Alcotest.(check int) "cancelled request dispatched once" 1 (F.post_count first);
  Alcotest.(check int) "cancellation never fails over" 0 (F.post_count second)
;;

let test_keeper_preparations_do_not_share_attempt_state () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc keeper ready-plan isolation"
      [ { id = "keeper-private-ready"; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ "keeper-private-ready" ] snapshot in
  let keeper_a =
    prepare_exn
      ~keeper_name:"keeper-a"
      ~registry
  in
  let keeper_b =
    prepare_exn
      ~keeper_name:"keeper-b"
      ~registry
  in
  let keeper_a_observation = observation_exn keeper_a "keeper-private-ready" in
  let keeper_b_observation = observation_exn keeper_b "keeper-private-ready" in
  Alcotest.(check bool)
    "independent preparations own distinct OAS call ids"
    true
    (not (String.equal keeper_a_observation.call_id keeper_b_observation.call_id));
  let result_a, result_b =
    Eio.Fiber.pair
      (fun () ->
         execute_prepared_lane ~keeper_name:"keeper-a" ~net ~clock keeper_a)
      (fun () ->
         execute_prepared_lane ~keeper_name:"keeper-b" ~net ~clock keeper_b)
  in
  ignore (completed_exn result_a : C.completed_plan);
  ignore (completed_exn result_b : C.completed_plan);
  check_observation
    ~label:"keeper A"
    ~phase:EO.Terminal
    ~dispatch_count:1
    (observation_exn keeper_a "keeper-private-ready");
  check_observation
    ~label:"keeper B"
    ~phase:EO.Terminal
    ~dispatch_count:1
    (observation_exn keeper_b "keeper-private-ready");
  Alcotest.(check int)
    "two Keeper-owned ready plans dispatch independently"
    2
    (F.post_count server)
;;

let test_prepared_lane_replay_is_terminal_without_second_post () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let slot_id = "single-use-replay" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc affine replay"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-affine-replay" ~registry in
  let retained_call_id = (observation_exn prepared slot_id).call_id in
  ignore
    (execute_prepared_lane
       ~keeper_name:"keeper-affine-replay"
       ~net
       ~clock
       prepared
     |> completed_exn
      : C.completed_plan);
  (match
     execute_prepared_lane
       ~keeper_name:"keeper-affine-replay"
       ~net
       ~clock
       prepared
   with
   | Error (C.Exact_attempt_already_started observation) ->
     Alcotest.(check string)
       "replay reports retained call id"
       retained_call_id
       observation.call_id
   | Error _ -> Alcotest.fail "replay returned the wrong typed terminal error"
   | Ok _ -> Alcotest.fail "same prepared lane replay unexpectedly succeeded");
  Alcotest.(check int) "replay cannot issue a second POST" 1 (F.post_count server)
;;

let test_prepared_lane_concurrency_is_affine () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let server =
    F.start_server ~sw ~net ~clock (F.Delay_then_reply (0.05, valid_response))
  in
  let slot_id = "single-use-concurrent" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc affine concurrency"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-affine-concurrent" ~registry in
  let retained_call_id = (observation_exn prepared slot_id).call_id in
  let first, second =
    Eio.Fiber.pair
      (fun () ->
         execute_prepared_lane
           ~keeper_name:"keeper-affine-concurrent-a"
           ~net
           ~clock
           prepared)
      (fun () ->
         execute_prepared_lane
           ~keeper_name:"keeper-affine-concurrent-b"
           ~net
           ~clock
           prepared)
  in
  (match first, second with
   | Ok _, Error (C.Exact_attempt_already_started observation)
   | Error (C.Exact_attempt_already_started observation), Ok _ ->
     Alcotest.(check string)
       "concurrent rejection reports retained call id"
       retained_call_id
       observation.call_id
   | _ ->
     Alcotest.fail "concurrent execution must yield one success and one affine rejection");
  Alcotest.(check int)
    "concurrent reuse cannot issue a second POST"
    1
    (F.post_count server)
;;

let test_before_rename_binding_failure_prevents_post () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let slot_id = "durable-guard-failure" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc durable guard failure"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-durable-guard-failure" ~registry in
  let guard : C.exact_execution_guard =
    { before_dispatch = (fun _ -> Error "injected before-rename binding failure")
    ; release_before_dispatch = (fun _ -> Alcotest.fail "release must not run")
    ; quarantine = (fun _ _ -> Alcotest.fail "quarantine must not run")
    }
  in
  (match
     execute_prepared_lane
       ~keeper_name:"keeper-durable-guard-failure"
       ~net
       ~clock
       ~exact_execution_guard:guard
       prepared
   with
   | Error C.Exact_execution_failed_before_dispatch -> ()
   | Error _ -> Alcotest.fail "guard failure returned the wrong typed failure"
   | Ok _ -> Alcotest.fail "guard failure must prevent exact-output execution");
  Alcotest.(check int) "before-rename binding failure prevents POST" 0 (F.post_count server)
;;

let test_missing_dispatch_guard_prevents_post () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let slot_id = "missing-dispatch-guard" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc missing durable dispatch guard"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-missing-dispatch-guard" ~registry in
  (match
     C.execute_prepared_lane
       ~keeper_name:"keeper-missing-dispatch-guard"
       ~net
       ~clock
       prepared
   with
   | Error C.Exact_execution_failed_before_dispatch -> ()
   | Error _ -> Alcotest.fail "missing guard returned the wrong typed failure"
   | Ok _ -> Alcotest.fail "missing guard must prevent exact-output execution");
  Alcotest.(check int) "missing guard prevents POST" 0 (F.post_count server)
;;

let test_quarantine_persistence_failure_preserves_original_cause () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let server = F.start_server ~sw ~net ~clock F.Abort_after_request in
  let slot_id = "quarantine-persistence-failure" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc terminal quarantine persistence failure"
      [ { id = slot_id; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-quarantine-persistence-failure" ~registry in
  let quarantine_calls = ref [] in
  let guard : C.exact_execution_guard =
    { before_dispatch = (fun _ -> Ok C.Durable)
    ; release_before_dispatch = (fun _ -> Alcotest.fail "release must not run")
    ; quarantine =
        (fun cause observation ->
           quarantine_calls := (cause, observation) :: !quarantine_calls;
           Error "injected terminal persistence failure")
    }
  in
  (match
     execute_prepared_lane
       ~keeper_name:"keeper-quarantine-persistence-failure"
       ~net
       ~clock
       ~exact_execution_guard:guard
       prepared
   with
   | Error (C.Exact_execution_failed_after_dispatch observation) ->
     Alcotest.(check string) "original failure slot" slot_id observation.slot_id
   | Error _ -> Alcotest.fail "quarantine failure returned the wrong typed terminal"
   | Ok _ -> Alcotest.fail "quarantine persistence failure unexpectedly succeeded");
  (match !quarantine_calls with
   | [ Keeper_event_queue_state.Execution_failed_after_dispatch, observation ] ->
     Alcotest.(check string) "quarantine retained slot" slot_id observation.slot_id
   | _ -> Alcotest.fail "quarantine did not receive the original terminal cause once");
  Alcotest.(check int) "terminal persistence failure never retries" 1 (F.post_count server)
;;

let test_heartbeat_guard_binds_before_post () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  with_temp_dir "masc-heartbeat-bind-before-post" @@ fun base_path ->
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
    "durable heartbeat binding exists when POST arrives"
    true
    (Atomic.get durable_binding_seen);
  Alcotest.(check int) "heartbeat guarded request posts once" 1 (F.post_count server)
;;

let test_visible_unknown_binding_prevents_post_and_settles () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  with_temp_dir "masc-visible-unknown-binding" @@ fun base_path ->
  let keeper_name = "keeper-visible-unknown-binding" in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  let slot_id = "visible-unknown-binding" in
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc visible unknown binding"
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
  let guard : C.exact_execution_guard =
    { durable_guard with
      before_dispatch =
        (fun observation ->
           match durable_guard.before_dispatch observation with
           | Ok C.Durable ->
             Ok (C.Visible_durability_unknown "injected bind after-rename failure")
           | Ok (C.Visible_durability_unknown _ as outcome) -> Ok outcome
           | Error _ as error -> error)
    }
  in
  let terminal : P.exact_execution_terminal =
    match
      execute_prepared_lane
        ~keeper_name
        ~net
        ~clock
        ~exact_execution_guard:guard
        prepared
    with
    | Error (C.Exact_execution_terminal terminal) -> terminal
    | Error _ -> Alcotest.fail "visible bind outcome returned the wrong typed terminal"
    | Ok _ -> Alcotest.fail "visible bind outcome must prevent exact-output execution"
  in
  Alcotest.(check bool)
    "visible bind outcome uses persistence terminal cause"
    true
    (terminal.cause = Keeper_event_queue_state.Terminal_persistence_failed);
  Alcotest.(check int) "visible bind outcome prevents POST" 0 (F.post_count server);
  (match P.exact_execution_binding_result ~base_path ~keeper_name with
   | Ok
       (Some
         { status = P.Dispatch_uncertain
         ; slot_id = persisted_slot_id
         ; call_id = persisted_call_id
         ; plan_fingerprint
         ; request_body_sha256
         ; _
         }) ->
     Alcotest.(check string)
       "visible bind retains slot identity"
       observation.slot_id
       persisted_slot_id;
     Alcotest.(check string)
       "visible bind retains call identity"
       observation.call_id
       persisted_call_id;
     Alcotest.(check string)
       "visible bind retains plan identity"
       observation.receipt_plan_fingerprint
       plan_fingerprint;
     Alcotest.(check string)
       "visible bind retains request identity"
       observation.receipt_request_body_sha256
       request_body_sha256
   | Ok (Some _) -> Alcotest.fail "visible bind retained the wrong status"
   | Ok None -> Alcotest.fail "visible bind was relabelled as unbound"
   | Error detail -> Alcotest.failf "visible bind reload failed: %s" detail);
  let settlement : P.settlement =
    P.No_compaction
      { source = persisted_checkpoint_source_exn "trace-visible-unknown-binding"
      ; reason = P.Exact_execution_terminal terminal
      }
  in
  (match
     P.settle_exact_execution_result
       ~base_path
       ~keeper_name
       ~settled_at:4.0
       ~lease
       ~slot_id:observation.slot_id
       ~call_id:observation.call_id
       ~plan_fingerprint:observation.receipt_plan_fingerprint
       ~request_body_sha256:observation.receipt_request_body_sha256
       ~settlement
       ()
   with
   | Ok (P.Settled _) -> ()
   | Ok _ -> Alcotest.fail "visible bind settlement was not fresh"
   | Error detail -> Alcotest.failf "visible bind settlement failed: %s" detail);
  match P.exact_execution_binding_result ~base_path ~keeper_name with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "visible bind settlement retained the binding"
  | Error detail -> Alcotest.failf "visible bind settlement reload failed: %s" detail
;;

let test_visible_unknown_quarantine_preserves_cause_and_settles () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  with_temp_dir "masc-visible-unknown-quarantine" @@ fun base_path ->
  let keeper_name = "keeper-visible-unknown-quarantine" in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  let slot_id = "visible-unknown-quarantine" in
  let server = F.start_server ~sw ~net ~clock (F.Reply domain_invalid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc visible unknown quarantine"
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
  let guard : C.exact_execution_guard =
    { durable_guard with
      quarantine =
        (fun cause observation ->
           match durable_guard.quarantine cause observation with
           | Ok C.Durable ->
             Ok (C.Visible_durability_unknown "injected quarantine after-rename failure")
           | Ok (C.Visible_durability_unknown _ as outcome) -> Ok outcome
           | Error _ as error -> error)
    }
  in
  let observation : C.attempt_observation =
    match
      execute_prepared_lane
        ~keeper_name
        ~net
        ~clock
        ~exact_execution_guard:guard
        prepared
    with
    | Error (C.Invalid_plan_after_dispatch observation) -> observation
    | Error _ -> Alcotest.fail "visible quarantine returned the wrong typed failure"
    | Ok _ -> Alcotest.fail "domain-invalid output unexpectedly succeeded"
  in
  let terminal : P.exact_execution_terminal =
    { cause = Keeper_event_queue_state.Domain_invalid_output
    ; slot_id = observation.slot_id
    ; call_id = observation.call_id
    }
  in
  Alcotest.(check int) "visible quarantine follows one POST" 1 (F.post_count server);
  (match P.exact_execution_binding_result ~base_path ~keeper_name with
   | Ok
       (Some
         { status = P.Terminal_quarantined persisted_cause
         ; slot_id = persisted_slot_id
         ; call_id = persisted_call_id
         ; _
         }) ->
     Alcotest.(check bool)
       "visible quarantine preserves canonical cause"
       true
       (persisted_cause = terminal.cause);
     Alcotest.(check string)
       "visible quarantine preserves canonical slot"
       terminal.slot_id
       persisted_slot_id;
     Alcotest.(check string)
       "visible quarantine preserves canonical call"
       terminal.call_id
       persisted_call_id
   | Ok (Some _) -> Alcotest.fail "visible quarantine retained the wrong status"
   | Ok None -> Alcotest.fail "visible quarantine was relabelled as unbound"
   | Error detail -> Alcotest.failf "visible quarantine reload failed: %s" detail);
  let settlement : P.settlement =
    P.No_compaction
      { source = persisted_checkpoint_source_exn "trace-visible-unknown-quarantine"
      ; reason = P.Exact_execution_terminal terminal
      }
  in
  (match
     P.settle_exact_execution_result
       ~base_path
       ~keeper_name
       ~settled_at:5.0
       ~lease
       ~slot_id:observation.slot_id
       ~call_id:observation.call_id
       ~plan_fingerprint:observation.receipt_plan_fingerprint
       ~request_body_sha256:observation.receipt_request_body_sha256
       ~settlement
       ()
   with
   | Ok (P.Settled _) -> ()
   | Ok _ -> Alcotest.fail "visible quarantine settlement was not fresh"
   | Error detail -> Alcotest.failf "visible quarantine settlement failed: %s" detail);
  match P.exact_execution_binding_result ~base_path ~keeper_name with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "visible quarantine settlement retained the binding"
  | Error detail ->
    Alcotest.failf "visible quarantine settlement reload failed: %s" detail
;;

let test_post_success_terminalization_is_affine () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  with_temp_dir "masc-post-success-terminal-affinity"
  @@ fun base_path ->
  let keeper_name = "keeper-post-success-terminal-affinity" in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  let slot_id = "post-success-terminal-affinity" in
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc post-success terminal affinity"
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
  let observation = C.completed_attempt_observation completed in
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
  Alcotest.(check int) "post-success quarantine runs once" 1 !quarantine_calls;
  Alcotest.(check bool)
    "different causes retain the first canonical terminal"
    true
    (first = second);
  Alcotest.(check bool)
    "first cause remains canonical"
    true
    (first.cause = Keeper_event_queue_state.Invalid_structural_evidence);
  let source =
    match Keeper_id.Trace_id.of_string "trace-post-success-terminal-affinity" with
    | Error detail -> Alcotest.failf "terminal source trace id failed: %s" detail
    | Ok trace_id ->
      (match
         Keeper_checkpoint_ref.of_persisted
           ~trace_id
           ~generation:1
           ~turn_count:1
           ~sha256:(String.make 64 'a')
       with
       | Ok source -> source
       | Error _ -> Alcotest.fail "terminal source checkpoint ref failed")
  in
  let settlement : P.settlement =
    P.No_compaction
      { source
      ; reason = P.Exact_execution_terminal second
      }
  in
  match
    P.settle_exact_execution_result
      ~base_path
      ~keeper_name
      ~settled_at:4.0
      ~lease
      ~slot_id:observation.slot_id
      ~call_id:observation.call_id
      ~plan_fingerprint:observation.receipt_plan_fingerprint
      ~request_body_sha256:observation.receipt_request_body_sha256
      ~settlement
      ()
  with
  | Ok (P.Settled receipt) ->
    (match P.exact_execution_binding_result ~base_path ~keeper_name with
     | Ok None -> ()
     | Ok (Some _) -> Alcotest.fail "settlement retained exact-execution binding"
     | Error detail -> Alcotest.failf "settled binding reload failed: %s" detail);
    (match P.active_lease_result ~base_path ~keeper_name with
     | Ok None -> ()
     | Ok (Some _) -> Alcotest.fail "settlement retained active lease"
     | Error detail -> Alcotest.failf "settled lease reload failed: %s" detail);
    let state =
      P.load_state_result ~base_path ~keeper_name
      |> require_ok "reload canonical terminal state"
    in
    Alcotest.(check int)
      "reloaded state has no lease"
      0
      (List.length (Keeper_event_queue_state.leases state));
    (match Keeper_event_queue_state.transition_outbox state with
     | [ { receipt = durable_receipt; _ } ] ->
       Alcotest.(check bool)
         "canonical terminal receipt is durable"
         true
         (receipt = durable_receipt);
       (match durable_receipt.settlement with
        | P.No_compaction
            { reason = P.Exact_execution_terminal durable_terminal; _ } ->
          Alcotest.(check bool)
            "durable terminal retains canonical cause and identity"
            true
            (durable_terminal = first)
        | _ -> Alcotest.fail "durable receipt lost canonical exact terminal")
     | _ -> Alcotest.fail "canonical terminal state has no exact durable receipt")
  | Ok (P.Already_settled _) ->
    Alcotest.fail "first canonical terminal settlement was already settled"
  | Ok (P.Committed_followup_failed { detail; _ }) ->
    Alcotest.failf "canonical terminal settlement follow-up failed: %s" detail
  | Error detail -> Alcotest.failf "canonical terminal settlement failed: %s" detail
;;

let test_post_success_terminalization_failures_preserve_canonical () =
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
         (label ^ " preserves canonical terminal")
         true
         (first = replay);
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

let () =
  Alcotest.run
    "compaction exact-output conformance"
    [ ( "preparation"
      , [ Alcotest.test_case
            "missing compaction lane is explicit degraded state"
            `Quick
            test_missing_compaction_lane_is_explicit_degraded_state
        ; Alcotest.test_case
            "ordered, effect-free, and one catalog generation"
            `Quick
            test_preparation_is_ordered_effect_free_and_single_generation
        ; Alcotest.test_case
            "published snapshot replacement cannot mix"
            `Quick
            test_published_snapshot_replacement_cannot_mix_prepared_lane
        ; Alcotest.test_case
            "missing credential is deferred past registry admission"
            `Quick
            test_missing_credential_is_deferred_past_registry_admission
        ; Alcotest.test_case
            "mixed unavailable slots are skipped in both orders"
            `Quick
            test_unavailable_slots_are_skipped_in_both_orders
        ; Alcotest.test_case
            "all unavailable slots return a typed error"
            `Quick
            test_all_unavailable_slots_are_typed
        ; Alcotest.test_case
            "unknown target is rejected by registry publication"
            `Quick
            test_unknown_target_is_rejected_by_registry_publication
        ] )
    ; ( "effect boundary"
      , [ Alcotest.test_case
            "Before_dispatch/0 advances exactly once"
            `Quick
            test_before_dispatch_zero_advances_exactly_once
        ; Alcotest.test_case
            "visible release uncertainty is source-bound terminal"
            `Quick
            test_visible_release_uncertainty_is_source_bound_terminal
        ; Alcotest.test_case
            "post-dispatch failure is terminal"
            `Quick
            test_post_dispatch_failure_is_terminal
        ; Alcotest.test_case
            "domain-invalid JSON is terminal"
            `Quick
            test_domain_invalid_json_is_terminal
        ; Alcotest.test_case
            "post-dispatch cancellation is typed and terminal"
            `Quick
            test_post_dispatch_cancellation_is_typed_terminal
        ; Alcotest.test_case
            "durable dispatch guard failure prevents POST"
            `Quick
            test_before_rename_binding_failure_prevents_post
        ; Alcotest.test_case
            "missing dispatch guard prevents POST"
            `Quick
            test_missing_dispatch_guard_prevents_post
        ; Alcotest.test_case
            "quarantine persistence failure preserves original cause"
            `Quick
            test_quarantine_persistence_failure_preserves_original_cause
        ; Alcotest.test_case
            "heartbeat durable bind precedes POST"
            `Quick
            test_heartbeat_guard_binds_before_post
        ; Alcotest.test_case
            "visible binding uncertainty prevents POST and settles"
            `Quick
            test_visible_unknown_binding_prevents_post_and_settles
        ; Alcotest.test_case
            "visible quarantine uncertainty preserves cause and settles"
            `Quick
            test_visible_unknown_quarantine_preserves_cause_and_settles
        ; Alcotest.test_case
            "post-success terminalization is affine"
            `Quick
            test_post_success_terminalization_is_affine
        ; Alcotest.test_case
            "post-success terminalization failures preserve canonical identity"
            `Quick
            test_post_success_terminalization_failures_preserve_canonical
        ] )
    ; ( "Keeper isolation"
      , [ Alcotest.test_case
            "prepared attempts are not shared"
            `Quick
            test_keeper_preparations_do_not_share_attempt_state
        ; Alcotest.test_case
            "prepared lane replay is affine"
            `Quick
            test_prepared_lane_replay_is_terminal_without_second_post
        ; Alcotest.test_case
            "prepared lane concurrency is affine"
            `Quick
            test_prepared_lane_concurrency_is_affine
        ] )
    ]
;;
