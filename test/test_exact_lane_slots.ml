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

let rests_on failure = Slots.rests (Slots.Cli_failed { runtime_id = "cli.a"; failure })

let test_a_cli_refusal_rests_only_on_its_account_standing () =
  check bool "a slot its provider holds rests" true
    (rests_on (Keeper_lane_cli_oneshot.Held { runtime_id = "cli.a"; until = 0. }));
  check bool "an unreadable answer does not rest" false
    (rests_on
       (Keeper_lane_cli_oneshot.Invalid_json_output { runtime_id = "cli.a"; detail = "not json" }));
  check bool "a request that cannot be one prompt does not rest" false
    (Slots.rests (Slots.Cli_unfit { runtime_id = "cli.a" }))
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

let failure_names passed =
  List.map
    (function
      | Walk.Failed
          { slot
          ; failure = Slots.Cli_failed { runtime_id = _; failure = Keeper_lane_cli_oneshot.Unknown_runtime _ }
          } -> "unknown " ^ Slots.id slot
      | Walk.Failed { slot; failure = _ } -> "other failure " ^ Slots.id slot
      | Walk.Held { slot; until = _ } -> "held " ^ Slots.id slot
      | Walk.Seats_full slot -> "full " ^ Slots.id slot)
    passed
;;

(* An unknown runtime is passed as its typed failure, and no client runs. *)
let test_a_cli_slot_with_no_runtime_fails_without_running_a_client () =
  Eio_main.run
  @@ fun env ->
  let ran = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr ran;
    Ok "{}"
  in
  let proceed _ = Ok () in
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
      [ unknown_runtime "ghost.a"; unknown_runtime "ghost.b" ]
  with
  | Walk.Exhausted { passed; standing } ->
    check (list string) "each slot failed as unknown" [ "unknown ghost.a"; "unknown ghost.b" ]
      (failure_names passed);
    check bool "an unknown runtime is not a rest" false
      (match standing with
       | Walk.Every_slot_resting -> true
       | Walk.Not_every_slot_resting -> false);
    check int "no client ran" 0 !ran
  | Walk.Answered _ | Walk.Stopped _ -> fail "the walk was meant to be exhausted"
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
            "a cli slot with no runtime fails without running a client"
            `Quick
            test_a_cli_slot_with_no_runtime_fails_without_running_a_client
        ] )
    ]
;;
