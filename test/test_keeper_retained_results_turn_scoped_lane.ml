(** A Keeper turn that still owes the model returned tool results reaches a
    turn-scoped Anthropic lane.

    The results a vendor turn left in the client tool outbox ride every
    request as one carrier until a turn consumes them. On a lane whose
    context carrier travels as turn-scoped system context, that context
    closes the request. A carrier placed after it made the codec refuse the
    request, and because only a completed turn empties the outbox, every
    later turn was refused the same way.

    The carrier is request data and is never stored, so its position must be
    one every round of the turn reproduces. Otherwise the signed reasoning
    of the previous round no longer matches the request it was bound to and
    is dropped from the tool loop. *)

open Masc
module Outbox = Keeper_client_tool_outbox

let fail = Alcotest.fail
let get = function Ok value -> value | Error detail -> fail detail
let keeper_name = "retained-results-turn-scoped"

let receipt : Outbox.receipt =
  { thread_id = "previous-vendor-session"
  ; turn_id = "previous-turn"
  ; call_id = "board-read"
  ; tool_name = "masc_board_list"
  ; arguments = `Assoc []
  ; response = `Assoc [ "content", `String "two posts"; "isError", `Bool false ]
  }
;;

let retained_carrier () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let base_path = Filename.temp_dir "retained-results-turn-scoped-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  ignore (Workspace.init (Workspace.default_config base_path) ~agent_name:(Some keeper_name));
  get (Outbox.retain ~base_path ~keeper_name receipt);
  match Outbox.context_message (get (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt)) with
  | Some carrier -> carrier
  | None -> fail "the retained result has a carrier"
;;

let message ?(origin = Llm_provider.Types.Conversation) role text : Agent_core.Types.message =
  { origin; role; content = [ Agent_core.Types.Text text ]; name = None; tool_call_id = None
  ; metadata = [] }
;;

(* The request a wake builds before the carrier joins it: the wake and the
   turn's context carrier as the turn-scoped lane transmits it. *)
let wake_request =
  [ message Agent_core.Types.User "autonomous turn"
  ; message ~origin:Llm_provider.Types.System_context Agent_core.Types.User
      "[system context] world state"
  ]
;;

let anthropic_lane_config () =
  let open Agent_core.Llm_provider in
  Provider_config.make ~kind:Anthropic ~model_id:"claude-sonnet-5-5"
    ~base_url:"https://api.anthropic.com" ~max_tokens:4096 ~system_prompt:"keeper system"
    ~model_capabilities_override:
      { (Capabilities.capabilities_of_kind Provider_config.Anthropic) with
        reasoning_replay_override = Capabilities.Force_turn_scoped_system_context_preserve_always
      }
    ()
;;

let roles_of_body body =
  let open Yojson.Safe.Util in
  body |> member "messages" |> to_list |> List.map (fun message -> member "role" message |> to_string)
;;

let test_a_wake_with_retained_results_reaches_the_lane () =
  let carrier = retained_carrier () in
  let request = Outbox.place_carrier carrier wake_request in
  let wire =
    match Agent_core.History.to_wire_messages (Agent_core.History.Memory_store.create ()) request with
    | Ok wire -> wire
    | Error error -> fail (Agent_core.Error.to_string (Agent_core.Error.Media error))
  in
  match
    Agent_core.Llm_provider.Backend_anthropic.build_request ~config:(anthropic_lane_config ())
      ~messages:wire ()
  with
  | exception Invalid_argument detail -> fail ("the Anthropic lane refuses the wake: " ^ detail)
  | body ->
    let body = Yojson.Safe.from_string body in
    Alcotest.(check (option string)) "the turn-scoped context still closes the request" (Some "system")
      (match List.rev (roles_of_body body) with last :: _ -> Some last | [] -> None);
    Alcotest.(check bool) "the returned result is in the request" true
      (String_util.contains_substring (Yojson.Safe.to_string body) "two posts")
;;

let media_ok = function
  | Ok value -> value
  | Error error -> fail (Agent_core.Error.to_string (Agent_core.Error.Media error))
;;

let to_wire messages =
  media_ok (Agent_core.History.to_wire_messages (Agent_core.History.Memory_store.create ()) messages)
;;

let board_tools =
  [ `Assoc
      [ "name", `String "masc_board_list"
      ; "description", `String "board fixture"
      ; "input_schema", `Assoc [ "type", `String "object" ]
      ]
  ]
;;

(* The assistant row the lane records for [request]: signed thinking and a
   tool call, bound by the real Anthropic producer to the request it
   answered. *)
let signed_tool_call ~config request =
  let open Agent_core.Llm_provider in
  let content =
    [ Types.Thinking { content = "read the board first"; signature = Some "sig-round-one" }
    ; Types.ToolUse { id = "call-1"; name = "masc_board_list"; input = `Assoc [] }
    ]
  in
  let reasoning_prefix =
    Backend_anthropic.transmitted_reasoning_prefix ~config ~messages:(to_wire request)
      ~tools:board_tools ~response_content:content ()
  in
  if Option.is_none reasoning_prefix then fail "the producer binds the reasoning to its request";
  let capability =
    match Reasoning_dialect.replay_capability_for_provider_config config with
    | Ok capability -> capability
    | Error detail -> fail detail
  in
  let response : Types.api_response =
    { id = "round-one"; model = "claude-sonnet-5-5"; unreadable_tool_uses = []
    ; stop_reason = Types.StopToolUse; content; usage = None
    ; telemetry =
        Some
          { Types.default_inference_telemetry with
            reasoning_source = Some capability.target; reasoning_prefix }
    }
  in
  match Types.assistant_message_of_response response with
  | Ok message ->
    media_ok (Agent_core.History.of_wire_message (Agent_core.History.Memory_store.create ()) message)
  | Error _ -> fail "the signed response is recorded"
;;

let test_signed_reasoning_survives_the_next_round () =
  let config = anthropic_lane_config () in
  let carrier = retained_carrier () in
  let first_round = Outbox.place_carrier carrier wake_request in
  let call = signed_tool_call ~config first_round in
  let stored_context =
    message ~origin:Llm_provider.Types.Historical_system_context Agent_core.Types.User
      "[system context] world state"
  in
  let result =
    { (message Agent_core.Types.Tool "") with
      content =
        [ Agent_core.Types.ToolResult
            { tool_use_id = "call-1"; content = "two posts"; outcome = Agent_core.Types.Tool_succeeded
            ; json = None; content_blocks = None }
        ]
    }
  in
  let second_round =
    Outbox.place_carrier carrier
      [ message Agent_core.Types.User "autonomous turn"
      ; stored_context
      ; call
      ; result
      ; message ~origin:Llm_provider.Types.System_context Agent_core.Types.User
          "[system context] world state after the call"
      ]
  in
  let call_index =
    match List.find_index (fun candidate -> candidate == call) second_round with
    | Some index -> index
    | None -> fail "the second round carries the call"
  in
  match
    Agent_core.Llm_provider.Backend_anthropic.retained_prefix_reasoning_indices ~config
      ~tools:board_tools (to_wire second_round)
  with
  | Ok (Some retained) ->
    Alcotest.(check (list int)) "the first round's signed thinking replays in the tool loop"
      [ call_index ] retained
  | Ok None -> fail "the Anthropic lane binds reasoning to its request"
  | Error error ->
    fail (Agent_core.Llm_provider.Reasoning_history_projection.error_to_string error)
;;

let test_the_carrier_follows_the_caller_query () =
  let carrier = retained_carrier () in
  let earlier = message Agent_core.Types.User "earlier wake" in
  let caller = message Agent_core.Types.User "autonomous turn" in
  let placed =
    Outbox.place_carrier carrier
      [ earlier
      ; message Agent_core.Types.Assistant "earlier answer"
      ; carrier
      ; caller
      ; message Agent_core.Types.Assistant "calling a tool"
      ]
  in
  Alcotest.(check int) "one carrier rides the request" 1
    (List.length (List.filter Outbox.is_context_message placed));
  Alcotest.(check bool) "the carrier comes right after the latest caller query" true
    (match List.find_index (fun candidate -> candidate == caller) placed with
     | Some index -> Option.fold ~none:false ~some:Outbox.is_context_message (List.nth_opt placed (index + 1))
     | None -> false)
;;

let () =
  Alcotest.run "keeper_retained_results_turn_scoped_lane"
    [ ( "retained results"
      , [ Alcotest.test_case "a wake with retained results reaches the turn-scoped lane" `Quick
            test_a_wake_with_retained_results_reaches_the_lane
        ; Alcotest.test_case "signed reasoning survives the next round" `Quick
            test_signed_reasoning_survives_the_next_round
        ; Alcotest.test_case "the carrier follows the caller query" `Quick
            test_the_carrier_follows_the_caller_query
        ] )
    ]
;;
