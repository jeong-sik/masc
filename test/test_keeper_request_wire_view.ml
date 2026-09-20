(* The request is composed in the durable vocabulary and projected for the
   wire afterwards (RFC keeper-context-window-in-tokens §10.4): the window
   counts atoms of the checkpoint history whatever the dialect deletes, so a
   front read from another runtime's record names the same atom here. *)

module Try_provider = Masc.Keeper_turn_driver_try_provider
module Front = Masc.Keeper_carried_front
module Types = Agent_core.Types
module Window = Runtime_model_input_tail_window
module Replay = Agent_core.Llm_provider.Reasoning_replay_contract

let message role content : Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }
;;

let user text = message Types.User [ Types.Text text ]
let assistant text = message Types.Assistant [ Types.Text text ]

(* A response that was only reasoning: the stream ended before any text or
   tool call, as a repeated-reasoning cut leaves it. *)
let reasoning_only text =
  message Types.Assistant [ Types.Thinking { content = text; signature = None } ]
;;

(* Sizes play no part here. *)
let measure_message_bytes (_ : Types.message) = 1

(* An OpenAI-compatible binding replays no reasoning: the projection deletes
   the thinking block, and an assistant message left with nothing the wire
   can carry is deleted whole. *)
let provider_config =
  Agent_core.Llm_provider.Provider_config.make
    ~kind:Agent_core.Llm_provider.Provider_config.OpenAI_compat
    ~model_id:"model-a"
    ~base_url:"https://provider.example"
    ()
;;

(* Seven atoms: every [User] and [Assistant] message opens one. *)
let history =
  [ user "one"
  ; assistant "1"
  ; user "two"
  ; reasoning_only "hmm"
  ; user "three"
  ; assistant "3"
  ; user "four"
  ]
;;

(* A front measured on [history]: its index and the message that opens it. *)
let seed first_atom : Front.seed =
  match Window.atom_opening_digest history first_atom with
  | Some front_digest -> { first_atom; front_digest; source = Front.Ledger }
  | None -> Alcotest.fail "the history has the seed's atom"
;;

let view ~front history : Try_provider.request_view =
  Try_provider.For_testing.request_view
    ~provider_config
    ~measure_message_bytes
    ~front
    ~history_digest_at:(Window.atom_opening_digest history)
    ~last_resort:false
    ~base_path:""
    ~demote_before:0
    ~materialize:(fun ~pending:_ messages -> messages)
    history
;;

(* A turn that did not finish is read at the position it reached. The range it
   tried is what the next turn sends, so a turn that failed for a reason that
   says nothing about size keeps its range instead of giving up half of it. *)
let test_a_response_observed_turns_range_is_read_where_it_started () =
  let ceiling = { (seed 0) with Front.source = Front.Turn_record { turn = 9 } } in
  let v = view ~front:(Some ceiling) history in
  let composed = v.Try_provider.composed in
  let observation =
    match
      Window.observe
        ~digest_at:(Window.atom_opening_digest history)
        ~history_atom_count:composed.Try_provider.history_atom_count
        composed.Try_provider.projection
    with
    | Some observation -> observation
    | None -> Alcotest.fail "a range that carried atoms reports its window"
  in
  Alcotest.(check int) "the recorded front carries all seven atoms" 7
    observation.Window.transmitted_atoms;
  Alcotest.(check string) "the origin names the response-observed turn" "turn_record#9"
    (Front.origin_to_string composed.Try_provider.origin)
;;

let declined error =
  Alcotest.fail
    (Agent_core.Llm_provider.Reasoning_history_projection.error_to_string error)
;;

(* A front at atom 2 carries five atoms of seven, and the record says so even
   though the wire carries four messages: the reasoning-only assistant message
   is deleted from the wire list, not from the history. *)
let test_the_window_counts_atoms_of_the_history_whatever_the_wire_deletes () =
  let v = view ~front:(Some (seed 2)) history in
  let composed = v.Try_provider.composed in
  let observation =
    match
      Window.observe
        ~digest_at:(Window.atom_opening_digest history)
        ~history_atom_count:composed.Try_provider.history_atom_count
        composed.Try_provider.projection
    with
    | Some observation -> observation
    | None -> Alcotest.fail "a range that carried atoms reports its window"
  in
  Alcotest.(check int) "seven atoms in the history" 7 observation.Window.total_atoms;
  Alcotest.(check int) "five carried" 5 observation.Window.transmitted_atoms;
  Alcotest.(check string) "the front is named by the history's atom 2"
    (seed 2).Front.front_digest
    observation.Window.front_atom_digest;
  Alcotest.(check int) "five messages carried" 5 (List.length v.Try_provider.carried);
  match v.Try_provider.wire with
  | Error error -> declined error
  | Ok wire -> Alcotest.(check int) "four messages on the wire" 4 (List.length wire)
;;

(* The contrast the order exists for: projected first, the same history has
   six atoms, every atom after the deleted one moves back one index, and a
   front measured on the history past that point opens with another message
   there: [for_history] drops it and the whole history starts over. *)
let test_projected_first_the_atom_count_would_be_the_dialects () =
  match
    Agent_core.Llm_provider.Complete_common.transmitted_history
      ~config:provider_config
      history
  with
  | Error error -> declined error
  | Ok projected ->
    let _, atoms = Window.annotate projected in
    Alcotest.(check int) "one atom fewer" 6 atoms;
    Alcotest.(check bool) "a front measured on the history is dropped there" true
      (Front.for_history ~digest_at:(Window.atom_opening_digest projected) (seed 4)
       = Error Front.Front_message_differs)
;;

(* Reasoning provenance on a [User] message is a malformed history: the
   projection declines, and the carried range is handed over as the
   checkpoint holds it for the backend to refuse with its typed error. *)
let test_a_declined_projection_hands_over_the_carried_range () =
  let source =
    match
      Types.Reasoning_source.create
        ~provider_kind:Agent_core.Llm_provider.Provider_config.OpenAI_compat
        ~provider_instance:
          (Types.Reasoning_source.provider_instance
             ~base_url:"https://provider.example"
             ~request_path:"/v1/chat/completions")
        ~canonical_model_id:"model-a"
        ~replay_contract:
          { Replay.replay_policy = Replay.No_replay
          ; streaming = Replay.No_streaming_reasoning
          ; output_wire = Replay.No_output_control
          }
    with
    | Ok source -> source
    | Error detail -> Alcotest.fail detail
  in
  let malformed =
    { (user "four") with Types.metadata = Types.Reasoning_source.metadata source }
  in
  let v = view ~front:None [ user "one"; assistant "1"; malformed ] in
  Alcotest.(check bool) "declined" true (Result.is_error v.Try_provider.wire);
  Alcotest.(check int) "the carried range stands in" 3 (List.length v.Try_provider.carried)
;;

let () =
  Alcotest.run
    "keeper_request_wire_view"
    [ ( "order"
      , [ Alcotest.test_case "the window counts atoms of the history" `Quick
            test_the_window_counts_atoms_of_the_history_whatever_the_wire_deletes
        ; Alcotest.test_case "projected first the count would be the dialect's" `Quick
            test_projected_first_the_atom_count_would_be_the_dialects
        ; Alcotest.test_case "an unfinished turn reads where it stopped" `Quick
            test_a_response_observed_turns_range_is_read_where_it_started
        ; Alcotest.test_case "a declined projection hands over the carried range" `Quick
            test_a_declined_projection_hands_over_the_carried_range
        ] )
    ]
;;
