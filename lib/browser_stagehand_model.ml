module Exact = Agent_core.Exact_output
module Registry = Runtime_exact_output_registry
module Wire = Browser_stagehand_wire

type role =
  | User
  | Assistant

type unserved_block =
  | Image_block
  | Tool_use_block
  | Tool_result_block

type block =
  | Text of string
  | Unserved of unserved_block

type message =
  { role : role
  ; content : block list
  }

type generation =
  | Structured of
      { name : string
      ; schema : Yojson.Safe.t
      }
  | Text_generation
  | Tool_generation of { tool_names : string list }

type request =
  { messages : message list
  ; system_prompt : string option
  ; temperature : float option
  ; stop_sequences : string list option
  ; generation : generation
  }

let ( let* ) = Result.bind

(* ---- Parsing [LLMGenerateParams] ---------------------------------------- *)

let field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let required key json ~at =
  Option.to_result ~none:(at ^ "." ^ key ^ " is missing") (field key json)
;;

let string_value ~at = function
  | `String value -> Ok value
  | _ -> Error (at ^ " is not a string")
;;

let list_value ~at = function
  | `List values -> Ok values
  | _ -> Error (at ^ " is not an array")
;;

let map_indexed ~at parse values =
  let rec walk index acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest ->
      let* parsed = parse ~at:(Printf.sprintf "%s[%d]" at index) value in
      walk (index + 1) (parsed :: acc) rest
  in
  walk 0 [] values
;;

let role_of_json ~at json =
  let* value = string_value ~at json in
  match value with
  | "user" -> Ok User
  | "assistant" -> Ok Assistant
  | other -> Error (Printf.sprintf "%s is %S, not user or assistant" at other)
;;

let block_of_json ~at json =
  let* kind = required "type" json ~at in
  let* kind = string_value ~at:(at ^ ".type") kind in
  match kind with
  | "text" ->
    let* text = required "text" json ~at in
    let* text = string_value ~at:(at ^ ".text") text in
    Ok (Text text)
  | "image" -> Ok (Unserved Image_block)
  | "tool_use" -> Ok (Unserved Tool_use_block)
  | "tool_result" -> Ok (Unserved Tool_result_block)
  | other -> Error (Printf.sprintf "%s.type is %S, not a protocol content block" at other)
;;

(* [LLMMessage.content] is one block or an array of blocks. *)
let content_of_json ~at = function
  | `List blocks -> map_indexed ~at block_of_json blocks
  | `Assoc _ as block ->
    let* block = block_of_json ~at block in
    Ok [ block ]
  | _ -> Error (at ^ " is neither a content block nor an array of them")
;;

let message_of_json ~at json =
  let* role = required "role" json ~at in
  let* role = role_of_json ~at:(at ^ ".role") role in
  let* content = required "content" json ~at in
  let* content = content_of_json ~at:(at ^ ".content") content in
  Ok { role; content }
;;

let optional key json ~at parse =
  match field key json with
  | None -> Ok None
  | Some value ->
    let* parsed = parse ~at:(at ^ "." ^ key) value in
    Ok (Some parsed)
;;

let float_value ~at = function
  | `Float value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | _ -> Error (at ^ " is not a number")
;;

let tool_name_of_json ~at json =
  let* name = required "name" json ~at in
  string_value ~at:(at ^ ".name") name
;;

type response_format =
  | Json_schema_format of
      { name : string
      ; schema : Yojson.Safe.t
      }
  | Text_format

let response_format_of_json ~at json =
  let* kind = required "type" json ~at in
  let* kind = string_value ~at:(at ^ ".type") kind in
  match kind with
  | "json_schema" ->
    let* name = required "name" json ~at in
    let* name = string_value ~at:(at ^ ".name") name in
    let* schema = required "schema" json ~at in
    Ok (Json_schema_format { name; schema })
  | "text" -> Ok Text_format
  | other -> Error (Printf.sprintf "%s.type is %S, not json_schema or text" at other)
;;

(* The protocol has two param shapes: structured (json_schema, no tools) and
   message (tools, text format). A request that mixes them fits neither. *)
let generation_of ~at ~response_format ~tool_names =
  match response_format, tool_names with
  | Some (Json_schema_format { name; schema }), (None | Some []) -> Ok (Structured { name; schema })
  | Some (Json_schema_format _), Some (_ :: _) ->
    Error (at ^ " declares tools with a json_schema response_format")
  | (None | Some Text_format), (None | Some []) -> Ok Text_generation
  | (None | Some Text_format), Some (_ :: _ as tool_names) -> Ok (Tool_generation { tool_names })
;;

let parse_params json =
  let at = "params" in
  match json with
  | `Assoc _ ->
    let* messages = required "messages" json ~at in
    let* messages = list_value ~at:(at ^ ".messages") messages in
    let* messages = map_indexed ~at:(at ^ ".messages") message_of_json messages in
    let* system_prompt = optional "system_prompt" json ~at string_value in
    let* temperature = optional "temperature" json ~at float_value in
    let* stop_sequences =
      optional "stop_sequences" json ~at (fun ~at value ->
        let* values = list_value ~at value in
        map_indexed ~at string_value values)
    in
    let* tool_names =
      optional "tools" json ~at (fun ~at value ->
        let* values = list_value ~at value in
        map_indexed ~at tool_name_of_json values)
    in
    let* response_format = optional "response_format" json ~at response_format_of_json in
    let* generation =
      generation_of ~at ~response_format ~tool_names
    in
    Ok
      { messages
      ; system_prompt
      ; temperature
      ; stop_sequences
      ; generation
      }
  | _ -> Error (at ^ " is not an object")
;;

(* ---- Lane admission ------------------------------------------------------- *)

type slot_refusal = System_prompt_not_accepted

type refused_slot =
  { slot_id : string
  ; refusal : slot_refusal
  }

type admitted_lane =
  { first_slot : Registry.selected_slot
  ; other_slots : Registry.selected_slot list
  ; refused_slots : refused_slot list
  }

type lane_refusal =
  | Cli_slots_declared of string list
  | No_slot_admitted of refused_slot list

(* The capability AGENT_CORE's own admission reads before it refuses a
   request that carries a system prompt ([Unsupported_system_prompt]). Reading
   it here refuses the slot once per lane resolution instead of once per
   dispatched request. *)
let slot_takes_system_prompt (slot : Registry.selected_slot) =
  (Exact.projection_target slot.admitted_target).capabilities
    .Llm_provider.Capabilities.supports_system_prompt
;;

let admit_lane (resolved : Registry.resolved_lane) =
  (* This bridge executes only AGENT_CORE HTTP candidates. Stagehand's usage
     field is optional; the CLI tail is refused because this bridge has no
     official-client executor yet, rather than silently skipping its slots. *)
  match resolved.cli_slots with
  | _ :: _ as cli_slots -> Error (Cli_slots_declared cli_slots)
  | [] ->
    let slots, refused_slots =
      List.partition_map
        (fun (slot : Registry.selected_slot) ->
           if slot_takes_system_prompt slot
           then Either.Left slot
           else Either.Right { slot_id = slot.slot_id; refusal = System_prompt_not_accepted })
        resolved.selected_slots
    in
    (match slots with
     | [] -> Error (No_slot_admitted refused_slots)
     | first_slot :: other_slots -> Ok { first_slot; other_slots; refused_slots })
;;

type lane_unavailable =
  | Registry_unavailable of Registry.publication_error
  | Lane_unresolved of Registry.lane_resolution_error

let published_lane () =
  match Registry.current () with
  | Error error -> Error (Registry_unavailable error)
  | Ok registry ->
    Registry.resolve_lane registry ~lane_id:(Runtime.exact_lane_id Runtime.Browser_stagehand)
    |> Result.map_error (fun error -> Lane_unresolved error)
;;

(* ---- Refusals ------------------------------------------------------------- *)

type no_callback_error = |

type flow_not_started =
  | Candidate_refused of Exact.flow_candidate_error
  | Snapshot_refused of Exact.flow_snapshot_error
  | Start_refused of Exact.flow_start_error

type unserved_generation =
  | Text_generation_requested
  | Tool_generation_requested of { tool_names : string list }

type refusal =
  | Params_malformed of string
  | Generation_not_served of unserved_generation
  | Content_not_served of unserved_block
  | Lane_unavailable of lane_unavailable
  | Lane_refused of lane_refusal
  | Flow_not_started of flow_not_started
  | Generation_failed of no_callback_error Exact.flow_execution_error

let unserved_block_name = function
  | Image_block -> "image"
  | Tool_use_block -> "tool_use"
  | Tool_result_block -> "tool_result"
;;

let refused_slot_to_string { slot_id; refusal = System_prompt_not_accepted } =
  slot_id ^ ": its model takes no system prompt"
;;

let refusal_to_string = function
  | Params_malformed detail -> "llm.generate params do not match the protocol: " ^ detail
  | Generation_not_served Text_generation_requested ->
    "text generation is not served; this lane answers json_schema requests only"
  | Generation_not_served (Tool_generation_requested { tool_names }) ->
    "tool generation is not served; the request declares tools: "
    ^ String.concat ", " tool_names
  | Content_not_served kind ->
    Printf.sprintf "%s content blocks are not served; send text blocks only"
      (unserved_block_name kind)
  | Lane_unavailable (Registry_unavailable error) ->
    "exact-output registry unavailable: " ^ Registry.publication_error_to_string error
  | Lane_unavailable (Lane_unresolved error) ->
    Registry.lane_resolution_error_to_string error
  | Lane_refused (Cli_slots_declared cli_slots) ->
    "the lane declares cli_slots, which it does not walk: " ^ String.concat ", " cli_slots
  | Lane_refused (No_slot_admitted refused) ->
    "no slot of the lane can take a system prompt: "
    ^ String.concat "; " (List.map refused_slot_to_string refused)
  | Flow_not_started (Candidate_refused Exact.Blank_flow_candidate_id) ->
    "a lane slot has a blank id"
  | Flow_not_started
      (Snapshot_refused (Exact.Duplicate_flow_candidate_id { candidate_id; _ })) ->
    "the lane names a slot twice: " ^ candidate_id
  | Flow_not_started (Start_refused (Exact.Flow_id_generation_failed detail)) ->
    "flow id generation failed: " ^ detail
  | Generation_failed error -> Keeper_exact_flow_detail.flow_execution_error_detail error
;;

let refusal_to_rpc_error refusal : Wire.rpc_error =
  { code = Wire.host_refused; message = refusal_to_string refusal }
;;

(* ---- Answer --------------------------------------------------------------- *)

let usage_json (usage : Agent_core.Types.api_usage) =
  (* The parsers write 0 for a cache count the body did not report (#38669),
     so only a positive count is a reported one. *)
  let cached =
    if usage.cache_read_input_tokens > 0
    then [ "cached_input_tokens", `Int usage.cache_read_input_tokens ]
    else []
  in
  `Assoc
    ([ "input_tokens", `Int usage.input_tokens
     ; "output_tokens", `Int usage.output_tokens
     ; "total_tokens", `Int (Agent_core.Types.total_tokens usage)
     ]
     @ cached)
;;

let answer_of_success (success : Exact.success) =
  let usage =
    match success.usage with
    | None -> []
    (* Some wire parsers fill an unreported token count with zero (#38669).
       This request has input text and a structured output, so either zero
       makes the report unsuitable for Stagehand's usage field. *)
    | Some usage when usage.input_tokens <= 0 || usage.output_tokens <= 0 -> []
    | Some usage -> [ "usage", usage_json usage ]
  in
  `Assoc
    ([ "role", `String "assistant"
     ; ( "content"
       , `Assoc
           [ "type", `String "text"; "text", `String (Yojson.Safe.to_string success.output) ] )
     ; "output_format", `String "json_schema"
     ; "structured_content", success.output
     ]
     @ usage)
;;

(* ---- Serving -------------------------------------------------------------- *)

let rec text_only = function
  | [] -> Ok ()
  | { content; role = _ } :: rest ->
    (match List.find_map (function Unserved kind -> Some kind | Text _ -> None) content with
     | Some kind -> Error (Content_not_served kind)
     | None -> text_only rest)
;;

let agent_core_message { role; content } =
  let role =
    match role with
    | User -> Agent_core.Types.User
    | Assistant -> Agent_core.Types.Assistant
  in
  Agent_core.Types.make_message
    ~role
    (List.filter_map
       (function
         | Text text -> Some (Agent_core.Types.Text text)
         | Unserved _ -> None)
       content)
;;

let exact_messages request =
  let conversation = List.map agent_core_message request.messages in
  match request.system_prompt with
  | None -> conversation
  | Some system_prompt ->
    Agent_core.Types.make_message ~role:Agent_core.Types.System
      [ Agent_core.Types.Text system_prompt ]
    :: conversation
;;

let start_flow ~(lane : admitted_lane) ~messages ~schema =
  let candidate (slot : Registry.selected_slot) =
    Exact.make_flow_candidate ~id:slot.slot_id ~admitted_target:slot.admitted_target
    |> Result.map_error (fun error -> Candidate_refused error)
  in
  let rec candidates = function
    | [] -> Ok []
    | slot :: rest ->
      let* candidate = candidate slot in
      let* rest = candidates rest in
      Ok (candidate :: rest)
  in
  let* first = candidate lane.first_slot in
  let* rest = candidates lane.other_slots in
  let requirement =
    Exact.make_output_requirement ~schema ~minimum_guarantee:Exact.Json_syntax
  in
  let* snapshot =
    Exact.snapshot_flow ~first ~rest ~messages requirement
    |> Result.map_error (fun error -> Snapshot_refused error)
  in
  Exact.start_flow snapshot |> Result.map_error (fun error -> Start_refused error)
;;

type no_rejection = |

let serve ~net ~clock ~resolve_lane params =
  let* request = parse_params params |> Result.map_error (fun detail -> Params_malformed detail) in
  let* schema =
    match request.generation with
    | Structured { schema; name = _ } -> Ok schema
    | Text_generation -> Error (Generation_not_served Text_generation_requested)
    | Tool_generation { tool_names } ->
      Error (Generation_not_served (Tool_generation_requested { tool_names }))
  in
  let* () = text_only request.messages in
  let* resolved = resolve_lane () |> Result.map_error (fun error -> Lane_unavailable error) in
  let* lane = admit_lane resolved |> Result.map_error (fun refusal -> Lane_refused refusal) in
  let* attempt =
    start_flow ~lane ~messages:(exact_messages request) ~schema
    |> Result.map_error (fun failure -> Flow_not_started failure)
  in
  let accept success : (Exact.flow_success, no_rejection) Exact.semantic_verdict =
    Exact.Accept success
  in
  match
    Exact.execute_flow_once
      ~net
      ~clock
      ~before_measurement_dispatch:(fun _ -> Ok ())
      ~on_measurement_terminal:(fun _ -> Ok ())
      ~before_dispatch:(fun _ -> Ok ())
      ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
      ~validate:accept
      attempt
  with
  | Ok validated -> Ok (answer_of_success (Exact.flow_success_output validated.accepted))
  | Error (Exact.Flow_execution_terminal { cause; prior_rejections = _ }) ->
    Error (Generation_failed cause)
  | Error (Exact.Flow_semantic_candidates_exhausted _) -> .
;;

let create ~net ~clock ~resolve_lane : Browser_stagehand_session.model =
  fun params -> serve ~net ~clock ~resolve_lane params |> Result.map_error refusal_to_rpc_error
;;
