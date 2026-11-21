(* Exact lane slots as the walker walks them (RFC
   exact-lane-walks-one-slot-list sections 3.3 to 3.6). No runtime is
   configured in this process, so every CLI slot names an unknown runtime:
   these cases cover what the walk decides before any client could run. *)

open Alcotest
open Masc
module Slots = Exact_lane_slots
module Walk = Exact_lane_walk
module Exact = Agent_core.Exact_output

let requirement =
  Exact.make_output_requirement
    ~schema:(`Assoc [ "type", `String "object" ])
    ~minimum_guarantee:Exact.Json_syntax
;;

let unknown_runtime runtime_id = Slots.Cli_slot { runtime_id; runtime = None }

(* An admitted HTTP target, so a slot can carry a real target. *)
let admitted_target () =
  let target : Exact.declared_target =
    { target_ref = "openrouter.probe"
    ; binding =
        Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.OpenAI_compat
          ~provider_id:"openrouter" ~model_id:"z-ai/glm-5.3-flash"
          ~base_url:"https://openrouter.ai/api/v1" ~request_path:"/chat/completions" ()
    ; credential = Exact.Credential_not_declared
    ; body_timeout_s = None
    ; model_declaration = Exact.No_model_declaration
    }
  in
  match Exact.load_resolver_snapshot ~catalog:(Exact.Embedded_with_targets [ target ]) () with
  | Error (_ : Exact.resolver_snapshot_error) -> fail "the fixture's resolver did not load"
  | Ok snapshot ->
    (match Exact.admit_target_ref snapshot target.target_ref with
     | Ok admitted -> admitted
     | Error (_ : Exact.target_catalog_admission_error) ->
       fail "the fixture's target was refused")
;;

let rests_on failure = Slots.rests (Slots.Cli_failed { runtime_id = "cli.a"; failure })

let test_a_cli_refusal_rests_only_on_its_account_standing () =
  check bool "a slot its provider holds rests" true
    (rests_on (Keeper_lane_cli_oneshot.Held { runtime_id = "cli.a"; until = 0. }));
  check bool "an unreadable answer does not rest" false
    (rests_on
       (Keeper_lane_cli_oneshot.Invalid_json_output { runtime_id = "cli.a"; detail = "not json" }));
  check bool "a request that cannot be one prompt does not rest" false
    (Slots.rests (Slots.Cli_unfit { runtime_id = "cli.a" }));
  check bool "a slot that cannot be a flow candidate does not rest" false
    (Slots.rests (Slots.Http_unfit { slot_id = ""; reason = "the slot has a blank id" }))
;;

let test_the_registry_lists_http_slots_then_cli_slots () =
  let slots =
    Slots.of_resolved_lane
      { Runtime_exact_output_registry.selected_slots = []; cli_slots = [ "ghost.a"; "ghost.b" ] }
  in
  check (list string) "the CLI slots in declared order" [ "ghost.a"; "ghost.b" ]
    (List.map Slots.id slots);
  check bool "a CLI slot with no runtime takes no seat" true
    (List.for_all
       (fun slot ->
          match Slots.seats ~admission_class:Llm_provider.Admission_class.Standard slot with
          | Walk.Seatless -> true
          | Walk.Seats_of _ -> false)
       slots)
;;

let test_the_failure_evidence_reads_each_pass_as_the_receipt_did () =
  let evidence = Slots.failure_evidence in
  let held = Walk.Held { slot = unknown_runtime "cli.held"; until = 0. } in
  let held_one_shot =
    Walk.Failed
      { slot = unknown_runtime "cli.held"
      ; failure =
          Slots.Cli_failed
            { runtime_id = "cli.held"
            ; failure = Keeper_lane_cli_oneshot.Held { runtime_id = "cli.held"; until = 0. }
            }
      }
  in
  let http =
    Slots.Http_slot
      { slot_id = "http.a"; admitted_target = admitted_target (); runtime_observation = None }
  in
  let held_http = Walk.Held { slot = http; until = 0. } in
  let unfit =
    Walk.Failed
      { slot = http; failure = Slots.Http_unfit { slot_id = "http.a"; reason = "blank id" } }
  in
  let full = Walk.Seats_full (unknown_runtime "cli.full") in
  let rejected =
    Walk.Failed
      { slot = unknown_runtime "cli.rejected"
      ; failure = Slots.Cli_rejected { runtime_id = "cli.rejected"; rejection = "not a verdict" }
      }
  in
  check bool "a walk that passed nothing says nothing" true
    (evidence [] = Keeper_exact_walk_failure.empty);
  check bool "a held slot reads as its account's rest refusal without the call" true
    (evidence [ held ] = Keeper_exact_walk_failure.held);
  check bool "a held slot reads as the one-shot's held refusal" true
    (evidence [ held ] = evidence [ held_one_shot ]);
  check bool "a held HTTP slot reads as a held CLI slot" true
    (evidence [ held_http ] = evidence [ held ]);
  check bool "an HTTP slot that could not become a candidate says nothing" true
    (evidence [ unfit ] = Keeper_exact_walk_failure.empty);
  check bool "a held slot does not say the input is too large" false
    (Keeper_exact_walk_failure.refuses_input_capacity (evidence [ held ]));
  check bool "a full slot says nothing" true (evidence [ full ] = Keeper_exact_walk_failure.empty);
  check bool "a rejected answer is invalid output" true
    (evidence [ rejected ]).Keeper_exact_walk_failure.invalid_output;
  check bool "the evidence of a walk joins its passes" true
    (evidence [ held; full; rejected ]
     = Keeper_exact_walk_failure.combine
         Keeper_exact_walk_failure.held
         Keeper_exact_walk_failure.invalid_output)
;;

let failure_names passed =
  List.map
    (function
      | Walk.Failed
          { slot
          ; failure = Slots.Cli_failed { runtime_id = _; failure = Keeper_lane_cli_oneshot.Unknown_runtime _ }
          } -> "unknown " ^ Slots.id slot
      | Walk.Failed { slot; failure = Slots.Http_unfit { slot_id = _; reason = _ } } ->
        "unfit"
      | Walk.Failed { slot; failure = _ } -> "other failure " ^ Slots.id slot
      | Walk.Held { slot; until = _ } -> "held " ^ Slots.id slot
      | Walk.Seats_full slot -> "full " ^ Slots.id slot)
    passed
;;

(* A walk over [slots] with a runner that counts its runs. *)
let walk_counting env slots =
  let ran = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr ran;
    Ok "{}"
  in
  let proceed _ = Ok () in
  let result =
    Slots.walk
      ~runner
      ~net:(Eio.Stdenv.net env)
      ~clock:(Eio.Stdenv.clock env)
      ~base_dir:"."
      ~admission_class:Llm_provider.Admission_class.Standard
      ~messages:[]
      ~requirement
      ~cli_request:(Some { Slots.system_prompt = ""; prompt = "say {}" })
      ~before_measurement_dispatch:proceed
      ~on_measurement_terminal:proceed
      ~before_dispatch:proceed
      ~validate_http:(fun (_ : Exact.flow_success) -> Exact.Reject_and_advance "unused")
      ~validate_cli:(fun (_ : Yojson.Safe.t) -> Ok ())
      ~before_cli_visit:(fun ~runtime_id:_ -> Ok ())
      ~on_advance:(fun ~failed:_ ~next:_ -> Ok ())
      slots
  in
  result, !ran
;;

(* An unknown runtime is passed as its typed failure, and no client runs. *)
let test_a_cli_slot_with_no_runtime_fails_without_running_a_client () =
  Eio_main.run
  @@ fun env ->
  match walk_counting env [ unknown_runtime "ghost.a"; unknown_runtime "ghost.b" ] with
  | Walk.Exhausted { passed; standing }, ran ->
    check (list string) "each slot failed as unknown" [ "unknown ghost.a"; "unknown ghost.b" ]
      (failure_names passed);
    check bool "an unknown runtime is not a rest" false
      (match standing with
       | Walk.Every_slot_resting -> true
       | Walk.Not_every_slot_resting -> false);
    check int "no client ran" 0 ran
  | (Walk.Answered _ | Walk.Stopped _), (_ : int) -> fail "the walk was meant to be exhausted"
;;

(* Inside a run's capture, each unknown runtime is recorded as the
   one-shot's refusal, in walk order, with nothing dispatched. *)
let test_a_run_capture_records_each_unknown_runtime_as_not_run () =
  Eio_main.run
  @@ fun env ->
  let capture = Exact_lane_slot_capture.create () in
  let (_ : (_, _, _) Slots.walk_result * int) =
    Exact_lane_slot_capture.with_capture capture (fun () ->
      walk_counting env [ unknown_runtime "ghost.a"; unknown_runtime "ghost.b" ])
  in
  match Exact_lane_slot_capture.observations capture with
  | None -> fail "the capture recorded nothing"
  | Some observations ->
    check (list string) "one observation per slot, in walk order" [ "ghost.a"; "ghost.b" ]
      (List.map (fun (observation : Exact_lane_slot_observation.t) -> observation.slot_id)
         observations);
    check bool "each is the client's refusal, not dispatched" true
      (List.for_all
         (fun (observation : Exact_lane_slot_observation.t) ->
            (not observation.generation_dispatched)
            &&
            match observation.outcome with
            | Exact_lane_slot_observation.Cli_failed cli ->
              not (Keeper_exact_walk_failure.cli_was_dispatched cli)
            | Exact_lane_slot_observation.Unresolved
            | Exact_lane_slot_observation.Accepted
            | Exact_lane_slot_observation.Semantic_rejected
            | Exact_lane_slot_observation.Admission_rejected _
            | Exact_lane_slot_observation.Execution_failed _ -> false)
         observations)
;;

(* A slot whose own declaration cannot start a flow is a failed visit, not a
   stop: RFC section 3.3 Q1 stops the walk only for masc's own failure. *)
let test_a_slot_its_own_declaration_cannot_start_does_not_stop_the_walk () =
  Eio_main.run
  @@ fun env ->
  let ran = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr ran;
    Ok "{}"
  in
  let proceed _ = Ok () in
  let slot : Runtime_exact_output_registry.selected_slot =
    { slot_id = ""; admitted_target = admitted_target (); runtime_observation = None }
  in
  let slots =
    Slots.of_resolved_lane
      { Runtime_exact_output_registry.selected_slots = [ slot ]
      ; cli_slots = [ "ghost.b" ]
      }
  in
  match
    Slots.walk
      ~runner
      ~net:(Eio.Stdenv.net env)
      ~clock:(Eio.Stdenv.clock env)
      ~base_dir:"."
      ~admission_class:Llm_provider.Admission_class.Standard
      ~messages:[]
      ~requirement
      ~cli_request:(Some { Slots.system_prompt = ""; prompt = "say {}" })
      ~before_measurement_dispatch:proceed
      ~on_measurement_terminal:proceed
      ~before_dispatch:proceed
      ~validate_http:(fun (_ : Exact.flow_success) -> Exact.Reject_and_advance "unused")
      ~validate_cli:(fun (_ : Yojson.Safe.t) -> Ok ())
      ~before_cli_visit:(fun ~runtime_id:_ -> Ok ())
      ~on_advance:(fun ~failed:_ ~next:_ -> Ok ())
      slots
  with
  | Walk.Exhausted { passed; standing } ->
    check (list string) "the blank slot is a failed visit, then the cli slot fails"
      [ "unfit"; "unknown ghost.b" ] (failure_names passed);
    check bool "neither failure is a rest" false
      (match standing with
       | Walk.Every_slot_resting -> true
       | Walk.Not_every_slot_resting -> false);
    check int "no client ran" 0 !ran
  | Walk.Answered _ | Walk.Stopped _ ->
    fail "a slot's own declaration error must not stop the walk"
;;

let () =
  run
    "exact_lane_slots"
    [ ( "slots"
      , [ test_case
            "a cli refusal rests only on the account's standing"
            `Quick
            test_a_cli_refusal_rests_only_on_its_account_standing
        ; test_case
            "the registry lists http slots then cli slots"
            `Quick
            test_the_registry_lists_http_slots_then_cli_slots
        ; test_case
            "the failure evidence reads each pass as the receipt did"
            `Quick
            test_the_failure_evidence_reads_each_pass_as_the_receipt_did
        ; test_case
            "a cli slot with no runtime fails without running a client"
            `Quick
            test_a_cli_slot_with_no_runtime_fails_without_running_a_client
        ; test_case
            "a slot its own declaration cannot start does not stop the walk"
            `Quick
            test_a_slot_its_own_declaration_cannot_start_does_not_stop_the_walk
        ; test_case
            "a run capture records each unknown runtime as not run"
            `Quick
            test_a_run_capture_records_each_unknown_runtime_as_not_run
        ] )
    ]
;;
