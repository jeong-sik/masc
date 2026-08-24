(** MASC-owned composition proof for the compaction AGENT_CORE exact-flow boundary.

    AGENT_CORE owns admission, affine attempts, execute-once, advancement, and receipt
    semantics. These tests observe only MASC-owned ordered opaque slot identity,
    source authority, domain validation, registry generation, and source
    terminalization. *)

open Masc

module C = Keeper_compaction_llm_summarizer
module F = Compaction_exact_output_fixture
module Registry = Runtime_exact_output_registry
module S = Keeper_structured_output_schema
module T = Agent_core.Types
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
(* [claim_manual_lease] built a lease for the removed exact-execution fence and
   already had no callers here. *)

let persisted_checkpoint_source_exn trace_id =
  match Keeper_id.Trace_id.of_string trace_id with
  | Error detail -> Alcotest.failf "checkpoint source trace id failed: %s" detail
  | Ok trace_id ->
    (match
       Keeper_checkpoint_ref.of_persisted
         ~trace_id
         ~turn_count:1
         ~sha256:(String.make 64 'a')
     with
     | Ok source -> source
     | Error _ -> Alcotest.fail "persisted checkpoint source ref failed")
;;

let execute_prepared_lane
      ~keeper_name
      ~net
      ?clock
      ?(before_dispatch_authority = fun _ -> Ok ())
      ?observation_registry
      prepared_lane
  =
  C.execute_prepared_lane
    ~keeper_name
    ~net
    ?clock
    ~before_dispatch_authority
    ?observation_registry
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

let plan_json ~summary ~keep_from_unit_index : Yojson.Safe.t =
  `Assoc
    [ S.compaction_plan_field_summary, `String summary
    ; S.compaction_plan_field_keep_from_unit_index, `Int keep_from_unit_index
    ]
;;

let valid_plan_json =
  plan_json ~summary:"first summary" ~keep_from_unit_index:1
;;

let domain_invalid_plan_json =
  plan_json ~summary:"invalid boundary" ~keep_from_unit_index:0
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
      ?(source_units = units)
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
      ~units:source_units
  with
  | Ok prepared -> prepared
  | Error _ -> Alcotest.fail "compaction flow preparation failed"
;;

let completed_exn = function
  | Ok completed -> completed
  | Error _ -> Alcotest.fail "compaction flow execution failed"
;;

let captured_observation_exn label = function
  | Some observation -> observation
  | None -> Alcotest.failf "%s did not observe an AGENT_CORE attempt identity" label
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
  match
    C.prepare_lane
      ~base_path:exact_flow_base_path
      ~keeper_name
      ~registry
      ~lane_id:"compaction_exact"
      ~units:
        [ U.Ordinary_message
            (message T.Assistant "one valid but irreducible source")
        ]
  with
  | Error C.Exact_lane_unconfigured -> ()
  | Error C.No_reducible_boundary ->
    Alcotest.fail "lane resolution must precede irreducible-window classification"
  | Error _ -> Alcotest.fail "missing lane returned the wrong typed failure"
  | Ok _ -> Alcotest.fail "missing lane must not be synthesized"
;;

let test_irreducible_window_is_a_distinct_terminal_noop () =
  let slot_id = "irreducible-window-slot" in
  let snapshot =
    F.resolver_snapshot
      ~source:"irreducible compaction window"
      [ { id = slot_id; base_url = "http://127.0.0.1:9" } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let keeper_name = "keeper-irreducible-window" in
  let source_units =
    [ U.Ordinary_message (message T.Assistant "only eligible source") ]
  in
  ensure_registered_keeper ~base_path:exact_flow_base_path keeper_name;
  match
    C.prepare_lane
      ~base_path:exact_flow_base_path
      ~keeper_name
      ~registry
      ~lane_id:conformance_lane_id
      ~units:source_units
  with
  | Error C.No_reducible_boundary -> ()
  | Error C.Invalid_plan ->
    Alcotest.fail "a valid irreducible window regressed to invalid_plan"
  | Error _ -> Alcotest.fail "irreducible window returned the wrong typed failure"
  | Ok _ -> Alcotest.fail "a one-source window cannot produce a reducing boundary"
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
  Alcotest.(check (list string))
    "AGENT_CORE freezes the effective candidate snapshot"
    [ "prepare-first"; "prepare-second" ]
    (C.For_testing.candidate_snapshot_slot_ids prepared);
  Alcotest.(check int)
    "preparation allocates no candidate attempt"
    0
    (List.length (C.For_testing.attempt_observations prepared));
  Alcotest.(check int) "preparation performs no first POST" 0 (F.post_count first);
  Alcotest.(check int) "preparation performs no second POST" 0 (F.post_count second)
;;

let test_preparation_bounds_oldest_window_by_exact_request_body () =
  let uncapped_slot_id = "uncapped-window-slot" in
  let bounded_slot_id = "bounded-window-slot" in
  let fixtures : F.target_fixture list =
    [ { id = uncapped_slot_id; base_url = "http://127.0.0.1:9" }
    ; { id = bounded_slot_id; base_url = "http://127.0.0.1:9" }
    ]
  in
  let slot_ids = [ uncapped_slot_id; bounded_slot_id ] in
  let source_units =
    List.init 4 (fun index ->
      U.Ordinary_message
        (message
           T.Assistant
           (Printf.sprintf "source-%d:%s" index (String.make 512 'x'))))
  in
  let uncapped_snapshot =
    F.resolver_snapshot ~source:"uncapped request projection" fixtures
  in
  let uncapped_registry =
    publish_exn ~slot_ids uncapped_snapshot
  in
  let admitted_target =
    match Registry.resolve_lane uncapped_registry ~lane_id:conformance_lane_id with
    | Ok { selected_slots = [ _; bounded_slot ] } ->
      bounded_slot.admitted_target
    | Ok _ | Error _ -> Alcotest.fail "fixture did not resolve both ordered slots"
  in
  let requirement =
    Agent_core.Exact_output.make_output_requirement
      ~schema:S.compaction_plan_output_schema
      ~minimum_guarantee:Agent_core.Exact_output.Json_syntax
  in
  let projection_bytes units =
    let window =
      match C.For_testing.planning_window_for_units units with
      | Ok window -> window
      | Error detail -> Alcotest.failf "projection window failed: %s" detail
    in
    match
      Agent_core.Exact_output.project_request_body
        ~target:admitted_target
        ~messages:(C.For_testing.messages_for_plan ~window)
        requirement
    with
    | Ok projection -> projection.actual_bytes
    | Error _ -> Alcotest.fail "credential-free request projection failed"
  in
  let two_unit_limit = projection_bytes (List.take 2 source_units) in
  Alcotest.(check bool)
    "third source makes the exact serialized body larger"
    true
    (projection_bytes (List.take 3 source_units) > two_unit_limit);
  let bounded_snapshot =
    F.resolver_snapshot
      ~request_body_limits:[ bounded_slot_id, two_unit_limit ]
      ~source:"bounded request projection"
      fixtures
  in
  let bounded_registry =
    publish_exn ~slot_ids bounded_snapshot
  in
  let prepared =
    prepare_exn
      ~source_units
      ~keeper_name:"keeper-bounded-window"
      ~registry:bounded_registry
      ()
  in
  Alcotest.(check (list int))
    "largest exact-fitting oldest prefix is selected"
    [ 0; 1 ]
    (C.For_testing.prepared_window_source_indices prepared);
  let first_unit_bytes = projection_bytes (List.take 1 source_units) in
  let rejecting_snapshot =
    F.resolver_snapshot
      ~request_body_limits:[ bounded_slot_id, first_unit_bytes - 1 ]
      ~source:"reject every request prefix"
      fixtures
  in
  let rejecting_registry =
    publish_exn ~slot_ids rejecting_snapshot
  in
  match
    C.prepare_lane
      ~base_path:exact_flow_base_path
      ~keeper_name:"keeper-rejected-window"
      ~registry:rejecting_registry
      ~lane_id:conformance_lane_id
      ~units:source_units
  with
  | Error C.Exact_admission_failed -> ()
  | Error _ | Ok _ ->
    Alcotest.fail "a lane that fits no atomic source prefix must fail closed"
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
    "MASC publication replaces the registry"
    true
    (not (registry_a == registry_b));
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

let test_source_authority_precedes_successor_post () =
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
      ~source:"masc AGENT_CORE advancement order"
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
  ignore
    (execute_prepared_lane
       ~keeper_name:"keeper-advance-order"
       ~net
       ~clock
       ~before_dispatch_authority:
         (fun observation ->
            push_event events ("authorize:" ^ observation.slot_id);
            Ok ())
       prepared
     |> completed_exn
      : C.completed_plan);
  Alcotest.(check (list string))
    "source authority precedes each AGENT_CORE dispatch"
    [ "authorize:unreachable-first"
    ; "authorize:successful-second"
    ; "post:second"
    ]
    !events;
  Alcotest.(check int) "successor dispatches once" 1 (F.post_count second);
  Alcotest.(check int) "success prevents another candidate" 0 (F.post_count third)
;;

let test_source_authority_rejection_prevents_post () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let server = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc source authority rejection"
      [ { id = "authority-rejection"; base_url = server.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ "authority-rejection" ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-authority-rejection" ~registry () in
  (match
     execute_prepared_lane
       ~keeper_name:"keeper-authority-rejection"
       ~net
       ~clock
       ~before_dispatch_authority:(fun _ -> Error "injected source rejection")
       prepared
   with
   | Error C.Exact_execution_authority_rejected -> ()
   | Error _ -> Alcotest.fail "authority rejection returned the wrong typed failure"
   | Ok _ -> Alcotest.fail "authority rejection unexpectedly executed");
  Alcotest.(check int) "authority rejection prevents POST" 0 (F.post_count server)
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
  let events = ref [] in
  (match
     execute_prepared_lane
       ~keeper_name:"keeper-domain-invalid"
       ~net
       ~clock
       ~before_dispatch_authority:
         (fun observation ->
            push_event events ("authorize:" ^ observation.slot_id);
            Ok ())
       prepared
   with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "declared semantic successor did not complete");
  Alcotest.(check int) "domain-invalid target posts once" 1 (F.post_count invalid);
  Alcotest.(check int) "declared successor posts once" 1 (F.post_count successor);
  Alcotest.(check (list string))
    "semantic successor receives its own source authority"
    [ "authorize:" ^ first_slot
    ; "authorize:declared-domain-successor"
    ]
    !events
;;

let test_summary_that_blocks_next_exact_fold_advances_to_successor () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let first_slot = "future-fold-blocked" in
  let successor_slot = "future-fold-successor" in
  let blocked_response =
    F.openai_response
      (plan_json
         ~summary:(String.make 20_000 'x')
         ~keep_from_unit_index:1)
  in
  let blocked = F.start_server ~sw ~net ~clock (F.Reply blocked_response) in
  let successor = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let fixtures : F.target_fixture list =
    [ { id = first_slot; base_url = blocked.base_url }
    ; { id = successor_slot; base_url = successor.base_url }
    ]
  in
  let slot_ids = [ first_slot; successor_slot ] in
  let uncapped_snapshot =
    F.resolver_snapshot
      ~source:"future fold request projection"
      fixtures
  in
  let uncapped_registry = publish_exn ~slot_ids uncapped_snapshot in
  let first_target =
    match
      Registry.resolve_lane
        uncapped_registry
        ~lane_id:conformance_lane_id
    with
    | Ok { selected_slots = first :: _ } -> first.admitted_target
    | Ok _ | Error _ ->
      Alcotest.fail "future-fold fixture did not resolve its first slot"
  in
  let initial_window =
    match C.For_testing.planning_window_for_units units with
    | Ok window -> window
    | Error detail ->
      Alcotest.failf "future-fold initial window failed: %s" detail
  in
  let requirement =
    Agent_core.Exact_output.make_output_requirement
      ~schema:S.compaction_plan_output_schema
      ~minimum_guarantee:Agent_core.Exact_output.Json_syntax
  in
  let initial_request_bytes =
    match
      Agent_core.Exact_output.project_request_body
        ~target:first_target
        ~messages:(C.For_testing.messages_for_plan ~window:initial_window)
        requirement
    with
    | Ok projection -> projection.actual_bytes
    | Error _ ->
      Alcotest.fail "future-fold initial request projection failed"
  in
  let bounded_snapshot =
    F.resolver_snapshot
      ~request_body_limits:[ first_slot, initial_request_bytes ]
      ~source:"future fold exact cap"
      fixtures
  in
  let bounded_registry = publish_exn ~slot_ids bounded_snapshot in
  let prepared =
    prepare_exn
      ~keeper_name:"keeper-future-fold"
      ~registry:bounded_registry
      ()
  in
  let events = ref [] in
  let completed =
    execute_prepared_lane
      ~keeper_name:"keeper-future-fold"
      ~net
      ~clock
      ~before_dispatch_authority:
        (fun observation ->
           push_event events ("authorize:" ^ observation.slot_id);
           Ok ())
      prepared
    |> completed_exn
  in
  Alcotest.(check string)
    "the smaller summary owns the completed exact evidence"
    successor_slot
    (C.completed_exact_execution_evidence completed
     |> C.exact_execution_evidence_slot_id);
  Alcotest.(check int)
    "future-blocking summary posts once"
    1
    (F.post_count blocked);
  Alcotest.(check int)
    "declared smaller-summary successor posts once"
    1
    (F.post_count successor);
  Alcotest.(check (list string))
    "future-blocking output advances under source authority"
    [ "authorize:" ^ first_slot
    ; "authorize:" ^ successor_slot
    ]
    !events
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
  (match
     execute_prepared_lane
       ~keeper_name:"keeper-semantic-exhaustion"
       ~net
       ~clock
       ~before_dispatch_authority:
         (fun observation ->
            push_event events ("authorize:" ^ observation.slot_id);
            Ok ())
       prepared
   with
   | Error (C.Exact_execution_terminal terminal) ->
     Alcotest.(check bool)
       "semantic exhaustion is domain-invalid"
       true
       (terminal.cause = Keeper_compaction_outcome.Domain_invalid_output);
     Alcotest.(check string) "final bound is terminalized" final_slot terminal.slot_id
   | Error _ -> Alcotest.fail "semantic exhaustion returned the wrong typed failure"
   | Ok _ -> Alcotest.fail "semantic exhaustion unexpectedly succeeded");
  Alcotest.(check (list string))
    "semantic exhaustion retains the final authorized source"
    [ "authorize:" ^ first_slot
    ; "authorize:" ^ final_slot
    ]
    !events
;;

let test_final_agent_core_flow_failure_is_generic_source_terminal () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let failed = F.start_server ~sw ~net ~clock F.Abort_after_request in
  let successor = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let first_slot = "generic-flow-failure" in
  let snapshot =
    F.resolver_snapshot
      ~source:"masc generic AGENT_CORE flow failure"
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
  let terminal =
    match
      execute_prepared_lane
        ~keeper_name:"keeper-flow-failure"
        ~net
        ~clock
        prepared
    with
    | Error (C.Exact_execution_terminal terminal) -> terminal
    | Error _ -> Alcotest.fail "AGENT_CORE flow failure returned the wrong failure"
    | Ok _ -> Alcotest.fail "failed AGENT_CORE flow unexpectedly succeeded"
  in
  Alcotest.(check bool)
    "generic terminal does not claim receipt phase"
    true
    (terminal.cause = Keeper_compaction_outcome.Exact_execution_failed);
  Alcotest.(check string) "generic terminal retains bound slot" first_slot terminal.slot_id;
  Alcotest.(check int) "failed request posts once" 1 (F.post_count failed);
  Alcotest.(check int) "terminal flow failure never advances" 0 (F.post_count successor)
;;

let test_observation_completion_failure_does_not_mask_source_terminal () =
  with_temp_dir "compaction-observation-failure-"
  @@ fun temp_dir ->
  run_eio
  @@ fun ~sw ~net ~clock ->
  let failed = F.start_server ~sw ~net ~clock F.Abort_after_request in
  let slot_id = "observation-write-failure" in
  let snapshot =
    F.resolver_snapshot
      ~source:"compaction observation completion failure"
      [ { id = slot_id; base_url = failed.base_url } ]
  in
  let registry = publish_exn ~slot_ids:[ slot_id ] snapshot in
  let prepared = prepare_exn ~keeper_name:"keeper-observation-failure" ~registry () in
  let observation_path = Filename.concat temp_dir "exact-lane-runs.jsonl" in
  let observation_registry = Exact_lane_run_registry.create ~path:observation_path () in
  let break_completion_path _observation =
    (* Registration has already fsynced by the time source authority runs.
       Replace the file with a directory so only the completion append fails. *)
    Sys.remove observation_path;
    Unix.mkdir observation_path 0o700;
    Ok ()
  in
  let terminal =
    match
      execute_prepared_lane
        ~keeper_name:"keeper-observation-failure"
        ~net
        ~clock
        ~before_dispatch_authority:break_completion_path
        ~observation_registry
        prepared
    with
    | Error (C.Exact_execution_terminal terminal) -> terminal
    | Error _ -> Alcotest.fail "observation failure changed the typed source terminal"
    | Ok _ -> Alcotest.fail "failed provider unexpectedly produced a compaction plan"
  in
  Alcotest.(check bool)
    "primary terminal survives the secondary write failure"
    true
    (terminal.cause = Keeper_compaction_outcome.Exact_execution_failed);
  Alcotest.(check string) "source identity survives" slot_id terminal.slot_id;
  Alcotest.(check int) "provider is dispatched exactly once" 1 (F.post_count failed);
  match Exact_lane_run_registry.list_runs observation_registry with
  | [ { status = Exact_lane_run_registry.Completion_persistence_failed
          { failure; _ }; _ } as run ] ->
    Alcotest.(check string)
      "failed observation append is explicitly uncertain"
      "completion_durability_unknown"
      (Exact_lane_run_registry.status_label run.status);
    Alcotest.(check bool)
      "failure detail survives"
      true
      (String.trim failure.detail <> "")
  | [ _ ] ->
    Alcotest.fail "failed observation append was not exposed as a persistence failure"
  | runs ->
    Alcotest.failf
      "expected one observation row after completion failure, got %d"
      (List.length runs)
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
  let outcome =
    match
      Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        let context = Eio.Promise.await cancel_context in
        F.await_first_request first;
        Eio.Cancel.cancel context Cancel_after_request_arrived;
        Eio.Promise.await_exn execution)
    with
    | value -> `Returned value
    | exception Eio.Time.Timeout ->
      Alcotest.fail "cancellation watchdog expired"
    | exception exn -> `Raised exn
  in
  (match outcome with
   | `Raised (Eio.Cancel.Cancelled Cancel_after_request_arrived) -> ()
   | `Raised exn ->
     Alcotest.failf
       "cancellation raised the wrong exception: %s"
       (Printexc.to_string exn)
   | `Returned (Error _) ->
     Alcotest.fail "cancellation was returned as a terminal instead of raised"
   | `Returned (Ok _) ->
     Alcotest.fail "cancelled flow unexpectedly succeeded");
  Alcotest.(check (list string))
    "only first identity was lifecycle-authorized"
    [ first_slot ]
    (List.rev !authorized);
  Alcotest.(check int) "cancelled request posts once" 1 (F.post_count first);
  Alcotest.(check int) "cancellation never dispatches successor" 0 (F.post_count successor)
;;

let test_admission_rejection_then_cancellation_propagates () =
  run_eio
  @@ fun ~sw ~net ~clock ->
  let first_slot = "semantic-rejection-before-admission-rejection" in
  let rejected_slot = "admission-rejected-without-dispatch" in
  let cancelled_slot = "cancelled-before-dispatch" in
  let first = F.start_server ~sw ~net ~clock (F.Reply domain_invalid_response) in
  let rejected = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let cancelled = F.start_server ~sw ~net ~clock (F.Reply valid_response) in
  let snapshot =
    F.resolver_snapshot
      ~api_key_envs:
        [ rejected_slot, "MASC_TEST_MISSING_COMPACTION_EXACT_KEY" ]
      ~source:"masc admission rejection retains prior authorized source"
      [ { id = first_slot; base_url = first.base_url }
      ; { id = rejected_slot; base_url = rejected.base_url }
      ; { id = cancelled_slot; base_url = cancelled.base_url }
      ]
  in
  let registry =
    publish_exn
      ~slot_ids:[ first_slot; rejected_slot; cancelled_slot ]
      snapshot
  in
  let prepared =
    prepare_exn
      ~keeper_name:"keeper-admission-rejection-cancelled"
      ~registry
      ()
  in
  let authorized = ref [] in
  let outcome =
    match
      Eio.Cancel.sub (fun context ->
        execute_prepared_lane
          ~keeper_name:"keeper-admission-rejection-cancelled"
          ~net
          ~clock
          ~before_dispatch_authority:
            (fun observation ->
               authorized := observation.slot_id :: !authorized;
               if String.equal observation.slot_id cancelled_slot
               then (
                 Eio.Cancel.cancel context Cancel_after_request_arrived;
                 Eio.Cancel.check context);
               Ok ())
          prepared)
    with
    | value -> `Returned value
    | exception exn -> `Raised exn
  in
  (match outcome with
   | `Raised (Eio.Cancel.Cancelled Cancel_after_request_arrived) -> ()
   | `Raised exn ->
     Alcotest.failf
       "cancellation raised the wrong exception: %s"
       (Printexc.to_string exn)
   | `Returned (Error _) ->
     Alcotest.fail "cancellation was returned as a terminal instead of raised"
   | `Returned (Ok _) ->
     Alcotest.fail "cancelled flow unexpectedly succeeded");
  Alcotest.(check (list string))
    "only admitted candidates reach source authority"
    [ first_slot; cancelled_slot ]
    (List.rev !authorized);
  Alcotest.(check int) "semantic rejection dispatched once" 1 (F.post_count first);
  Alcotest.(check int) "admission rejection did not dispatch" 0 (F.post_count rejected);
  Alcotest.(check int)
    "cancelled authority did not dispatch"
    0
    (F.post_count cancelled)
;;


(* The four identifiers on a compaction terminal say which call failed; none of
   them says why. Measured on a live compaction that spent 470 s on
   glm-coding.glm-5-turbo — a slot completing 97% of its work elsewhere — and
   left only slot_id, call_id, and two fingerprints. The sibling consumer of the
   same agent-core branch (hitl_summary_worker) was already rendering the
   provider's account; compaction discarded it in the pattern match. *)
let test_terminal_carries_the_provider_account () =
  let base : Keeper_compaction_outcome.exact_execution_terminal =
    { cause = Keeper_compaction_outcome.Exact_execution_failed
    ; slot_id = "glm-coding.glm-5-turbo"
    ; call_id = "call-fixture"
    ; plan_fingerprint = "plan-fixture"
    ; request_body_sha256 = String.make 64 'a'
    ; detail = None
    }
  in
  let render t = Keeper_compaction_outcome.exact_execution_terminal_to_string t in
  let contains needle text =
    let n = String.length needle in
    let rec scan i =
      i + n <= String.length text && (String.sub text i n = needle || scan (i + 1))
    in
    scan 0
  in
  (* Control: without an account the rendering is exactly what it was before
     this field existed. A change here would be a silent format break for every
     terminal that has no provider account to carry. *)
  let without = render base in
  Alcotest.(check bool) "keeps the identifiers" true (contains "slot_id=glm-coding.glm-5-turbo" without);
  Alcotest.(check bool) "adds nothing when there is no account" false (contains "detail=" without);
  (* An empty account is the same as none: a bare "detail=" would read as an
     account that says nothing, which is worse than not claiming one. *)
  Alcotest.(check bool) "blank account is not rendered" false
    (contains "detail=" (render { base with detail = Some "   " }));
  let with_account = render { base with detail = Some "slot=x completion failed (http_status=429)" } in
  Alcotest.(check bool) "carries the account" true (contains "detail=slot=x completion failed" with_account);
  Alcotest.(check bool) "still carries the identifiers" true
    (contains "call_id=call-fixture" with_account)
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
            "irreducible window is a terminal no-op"
            `Quick
            test_irreducible_window_is_a_distinct_terminal_noop
        ; Alcotest.test_case
            "order and generation freeze before attempt allocation"
            `Quick
            test_preparation_freezes_order_generation_and_defers_attempt_identity
        ; Alcotest.test_case
            "request body cap bounds oldest window"
            `Quick
            test_preparation_bounds_oldest_window_by_exact_request_body
        ; Alcotest.test_case
            "replacement cannot mix prepared generation"
            `Quick
            test_published_replacement_cannot_mix_prepared_generation
        ] )
    ; ( "source authority"
      , [ Alcotest.test_case
            "authority precedes successor POST"
            `Quick
            test_source_authority_precedes_successor_post
        ; Alcotest.test_case
            "authority rejection prevents POST"
            `Quick
            test_source_authority_rejection_prevents_post
        ; Alcotest.test_case
            "lifecycle authority permits dispatch"
            `Quick
            test_dispatch_authority_without_queue_guard
        ] )
    ; ( "terminal ownership"
      , [ Alcotest.test_case
            "domain invalidity advances to declared successor"
            `Quick
            test_domain_invalid_output_advances_to_declared_successor
        ; Alcotest.test_case
            "future-fold blocking summary advances to successor"
            `Quick
            test_summary_that_blocks_next_exact_fold_advances_to_successor
        ; Alcotest.test_case
            "final AGENT_CORE failure is generic terminal"
            `Quick
            test_final_agent_core_flow_failure_is_generic_source_terminal
        ; Alcotest.test_case
            "observation completion failure preserves source terminal"
            `Quick
            test_observation_completion_failure_does_not_mask_source_terminal
        ; Alcotest.test_case
            "semantic exhaustion terminalizes final bound"
            `Quick
            test_semantic_exhaustion_terminalizes_final_bound
        ; Alcotest.test_case
            "cancellation preserves lifecycle-authorized identity"
            `Quick
            test_cancellation_preserves_lifecycle_authorized_identity
        ; Alcotest.test_case
            "admission rejection then cancellation propagates"
            `Quick
            test_admission_rejection_then_cancellation_propagates
        ; Alcotest.test_case
            "terminal carries the provider account"
            `Quick
            test_terminal_carries_the_provider_account
        ] )
      (* The "affinity and non-sharing" group held only cases whose functions
         #25993 removed; its registrations were left behind and the group is now
         empty. See #26013. *)
    ]
;;
