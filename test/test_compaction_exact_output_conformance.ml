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
        (Runtime_exact_output_registry.error_to_string error)
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
  (match Registry.resolve_slots registry [ slot_id ] with
   | [ Error _ ] -> ()
   | [ Ok _ ] -> Alcotest.fail "missing credential must fail target selection"
   | outcomes ->
     Alcotest.failf "expected one credential-gated slot, got %d" (List.length outcomes));
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
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown target must not publish in the MASC registry"
;;

let check_failure label expected = function
  | Error actual when actual = expected -> ()
  | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label
  | Error _ -> Alcotest.failf "%s returned the wrong failure class" label
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
    C.execute_prepared_lane
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
    (C.execute_prepared_lane
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
  C.execute_prepared_lane ~keeper_name:"keeper-post-dispatch" ~net prepared
  |> check_failure "post-dispatch failure" C.Exact_execution_failed_after_dispatch;
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
  C.execute_prepared_lane ~keeper_name:"keeper-domain-invalid" ~net prepared
  |> check_failure "domain-invalid output" C.Invalid_plan;
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

let test_timeout_cancellation_escapes_without_failover () =
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
        C.execute_prepared_lane
          ~keeper_name:"keeper-cancelled"
          ~net
          ~clock
          prepared))
  in
  let cancellation_propagated =
    try
      Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        let context = Eio.Promise.await cancel_context in
        F.await_first_request first;
        Eio.Cancel.cancel context Cancel_after_request_arrived;
        try
          ignore
            (Eio.Promise.await_exn execution
              : (C.completed_plan, C.summarization_failure) result);
          false
        with
        | Eio.Cancel.Cancelled Cancel_after_request_arrived -> true)
    with
    | Eio.Time.Timeout ->
      Alcotest.fail "request-arrival cancellation watchdog expired"
  in
  Alcotest.(check bool)
    "caller cancellation escapes compaction"
    true
    cancellation_propagated;
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
  let result_a, result_b =
    Eio.Fiber.pair
      (fun () ->
         C.execute_prepared_lane ~keeper_name:"keeper-a" ~net ~clock keeper_a)
      (fun () ->
         C.execute_prepared_lane ~keeper_name:"keeper-b" ~net ~clock keeper_b)
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
            "post-dispatch failure is terminal"
            `Quick
            test_post_dispatch_failure_is_terminal
        ; Alcotest.test_case
            "domain-invalid JSON is terminal"
            `Quick
            test_domain_invalid_json_is_terminal
        ; Alcotest.test_case
            "timeout cancellation escapes without failover"
            `Quick
            test_timeout_cancellation_escapes_without_failover
        ] )
    ; ( "Keeper isolation"
      , [ Alcotest.test_case
            "prepared attempts are not shared"
            `Quick
            test_keeper_preparations_do_not_share_attempt_state
        ] )
    ]
;;
