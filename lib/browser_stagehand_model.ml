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
  { http_slots : Registry.selected_slot list
  ; cli_slots : string list
  ; refused_slots : refused_slot list
  }

type lane_refusal = No_slot_admitted of refused_slot list

(* The capability AGENT_CORE's own admission reads before it refuses a
   request that carries a system prompt ([Unsupported_system_prompt]). Reading
   it here refuses the slot once per lane resolution instead of once per
   dispatched request. *)
let slot_takes_system_prompt (slot : Registry.selected_slot) =
  (Exact.projection_target slot.admitted_target).capabilities
    .Llm_provider.Capabilities.supports_system_prompt
;;

(* An official-client one-shot takes the system prompt as its own argument,
   so every declared CLI slot is kept; only HTTP slots are read for the
   capability. *)
let admit_lane (resolved : Registry.resolved_lane) =
  let http_slots, refused_slots =
    List.partition_map
      (fun (slot : Registry.selected_slot) ->
         if slot_takes_system_prompt slot
         then Either.Left slot
         else Either.Right { slot_id = slot.slot_id; refusal = System_prompt_not_accepted })
      resolved.selected_slots
  in
  match http_slots, resolved.cli_slots with
  | [], [] -> Error (No_slot_admitted refused_slots)
  | _, _ -> Ok { http_slots; cli_slots = resolved.cli_slots; refused_slots }
;;

type lane_unavailable =
  | Registry_unavailable of Registry.publication_error
  | Lane_unresolved of Registry.lane_resolution_error

let published_lane () =
  match Registry.current () with
  | Error error -> Error (Registry_unavailable error)
  | Ok registry ->
    Registry.resolve_lane registry ~lane_id:(Standalone_lane.to_id Standalone_lane.Browser_stagehand)
    |> Result.map_error (fun error -> Lane_unresolved error)
;;

(* ---- Refusals ------------------------------------------------------------- *)

type no_callback_error = |

(* The flow's callbacks all answer [Ok ()], so the renderer's callback arms
   are unreachable by type (the same shape as the Librarian runtime's). *)
let no_callback_error_to_string : no_callback_error -> string = function
  | _ -> .
;;

type flow_not_started =
  | Candidate_refused of Exact.flow_candidate_error
  | Snapshot_refused of Exact.flow_snapshot_error
  | Start_refused of Exact.flow_start_error

type unserved_generation =
  | Text_generation_requested
  | Tool_generation_requested of { tool_names : string list }

type cli_unfit = Assistant_turn_in_conversation

type cli_tail =
  | Cli_tail_undeclared
  | Cli_tail_unfit of cli_unfit
  | Cli_tail_exhausted of Keeper_lane_cli_oneshot.failure list

type output_shape_issue =
  | Missing_required_key of string
  | Incompatible_required_shape of string

type rejected_http_output =
  { slot_id : string
  ; issue : output_shape_issue
  }

let output_shape_issue_to_string = function
  | Missing_required_key at -> "missing required key " ^ at
  | Incompatible_required_shape at -> "incompatible required shape at " ^ at
;;

(* A deliberately narrow pre-Zod guard: check JSON Schema's required object
   keys, the primitive type at each visited property, and anyOf alternatives.
   This catches missing Stagehand act fields before the HTTP lane decides
   failover. The extension still owns complete schema validation. *)
let rec required_shape_issue ~at schema output =
  match field "anyOf" schema with
  | Some (`List (_ :: _ as alternatives)) ->
    let issues = List.map (fun alternative -> required_shape_issue ~at alternative output) alternatives in
    if List.exists Option.is_none issues then None else List.find_map Fun.id issues
  | Some _ | None ->
    let type_matches =
      match field "type" schema, output with
      | Some (`String "object"), `Assoc _
      | Some (`String "array"), `List _
      | Some (`String "string"), `String _
      | Some (`String "boolean"), `Bool _
      | Some (`String "integer"), (`Int _ | `Intlit _)
      | Some (`String "number"), (`Int _ | `Intlit _ | `Float _)
      | Some (`String "null"), `Null -> true
      | Some (`String ("object" | "array" | "string" | "boolean" | "integer" | "number" | "null")), _ -> false
      | Some _ | None -> true
    in
    if not type_matches
    then Some (Incompatible_required_shape at)
    else
      match output with
      | `Assoc fields ->
        let required =
          match field "required" schema with
          | Some (`List keys) ->
            List.filter_map (function `String key -> Some key | _ -> None) keys
          | Some _ | None -> []
        in
        (match List.find_opt (fun key -> not (List.mem_assoc key fields)) required with
         | Some key -> Some (Missing_required_key (at ^ "." ^ key))
         | None ->
           (match field "properties" schema with
            | Some (`Assoc properties) ->
              List.find_map
                (fun (key, property_schema) ->
                   match List.assoc_opt key fields with
                   | None -> None
                   | Some value ->
                     required_shape_issue ~at:(at ^ "." ^ key) property_schema value)
                properties
            | Some _ | None -> None))
      | _ ->
        if Option.is_some (field "required" schema)
           || Option.is_some (field "properties" schema)
        then Some (Incompatible_required_shape at)
        else None
;;

type generation_failure =
  { http_failure : no_callback_error Exact.flow_execution_error option
  ; rejected_http_outputs : rejected_http_output list
  ; cli_tail : cli_tail
  }

type refusal =
  | Params_malformed of string
  | Generation_not_served of unserved_generation
  | Content_not_served of unserved_block
  | Lane_unavailable of lane_unavailable
  | Lane_refused of lane_refusal
  | Flow_not_started of flow_not_started
  | Generation_failed of generation_failure

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
  | Lane_refused (No_slot_admitted refused) ->
    "the lane declares no cli_slots and no HTTP slot of it can take a system prompt: "
    ^ String.concat "; " (List.map refused_slot_to_string refused)
  | Flow_not_started (Candidate_refused Exact.Blank_flow_candidate_id) ->
    "a lane slot has a blank id"
  | Flow_not_started
      (Snapshot_refused (Exact.Duplicate_flow_candidate_id { candidate_id; _ })) ->
    "the lane names a slot twice: " ^ candidate_id
  | Flow_not_started (Start_refused (Exact.Flow_id_generation_failed detail)) ->
    "flow id generation failed: " ^ detail
  | Generation_failed { http_failure; rejected_http_outputs; cli_tail } ->
    let http =
      Option.map
        (Exact.flow_execution_error_to_string
           ~callback_error_to_string:no_callback_error_to_string
           ~raw_response_to_string:Keeper_exact_flow_detail.raw_response_excerpt)
        http_failure
    in
    let rejected =
      match rejected_http_outputs with
      | [] -> None
      | refusals ->
        Some
          ("HTTP slots rejected required JSON shape: "
           ^ String.concat "; "
               (List.map
                  (fun { slot_id; issue } ->
                     slot_id ^ ": " ^ output_shape_issue_to_string issue)
                  refusals))
    in
    let cli =
      match cli_tail with
      | Cli_tail_undeclared -> None
      | Cli_tail_unfit Assistant_turn_in_conversation ->
        Some
          "the cli_slots were not walked: an official-client one-shot takes one \
           prompt, and this conversation has an assistant turn whose role it \
           cannot carry"
      | Cli_tail_exhausted failures ->
        Some
          ("every cli slot failed: "
           ^ String.concat "; " (List.map Keeper_lane_cli_oneshot.failure_to_string failures))
    in
    String.concat "; " (List.filter_map Fun.id [ http; rejected; cli ])
;;

let refusal_to_rpc_error refusal : Wire.rpc_error =
  { code = Wire.host_refused; message = refusal_to_string refusal }
;;

(* The extension gets the detailed refusal. The server records a bounded,
   closed cause without copying extension-supplied tool names or provider text
   into its log. *)
let refusal_kind = function
  | Params_malformed _ -> "params_malformed"
  | Generation_not_served _ -> "generation_not_served"
  | Content_not_served _ -> "content_not_served"
  | Lane_unavailable _ -> "lane_unavailable"
  | Lane_refused _ -> "lane_refused"
  | Flow_not_started _ -> "flow_not_started"
  | Generation_failed _ -> "generation_failed"
;;

(* ---- Answer --------------------------------------------------------------- *)

let usage_json (usage : Agent_core.Types.api_usage) =
  (* WORKAROUND(#38669): parsers write 0 for an unreported cache count.
     Remove this guard once api_usage carries an optional count. *)
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

let answer_json ~output ~usage =
  `Assoc
    ([ "role", `String "assistant"
     ; "content", `Assoc [ "type", `String "text"; "text", `String (Yojson.Safe.to_string output) ]
     ; "output_format", `String "json_schema"
     ; "structured_content", output
     ]
     @ usage)
;;

let answer_of_success (success : Exact.success) =
  let usage =
    match success.usage with
    | None -> []
    (* WORKAROUND(#38669): wire parsers fill unreported counts with zero.
       This request has input text and a structured output, so either zero
       makes the report unsuitable for Stagehand's usage field. Remove this
       guard once api_usage carries optional input and output counts. *)
    | Some usage when usage.input_tokens <= 0 || usage.output_tokens <= 0 -> []
    | Some usage -> [ "usage", usage_json usage ]
  in
  answer_json ~output:success.output ~usage
;;

(* An official-client one-shot reports no token usage, and Stagehand's usage
   field is optional, so the key is left out. *)
let answer_of_cli_output output = answer_json ~output ~usage:[]

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

let start_flow ~first_slot ~other_slots ~messages ~requirement =
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
  let* first = candidate first_slot in
  let* rest = candidates other_slots in
  let* snapshot =
    Exact.snapshot_flow ~first ~rest ~messages requirement
    |> Result.map_error (fun error -> Snapshot_refused error)
  in
  Exact.start_flow snapshot |> Result.map_error (fun error -> Start_refused error)
;;

(* ---- CLI tail --------------------------------------------------------------- *)

(* An official-client one-shot takes one prompt and a separate system prompt.
   User turns join into that prompt in order; an assistant turn has no place
   in it that keeps its role, so such a conversation is not sent. *)
let cli_prompt messages =
  let rec texts acc = function
    | [] -> Ok (String.concat "\n\n" (List.rev acc))
    | { role = Assistant; content = _ } :: _ -> Error Assistant_turn_in_conversation
    | { role = User; content } :: rest ->
      let text =
        String.concat
          "\n\n"
          (List.filter_map
             (function
               | Text text -> Some text
               | Unserved _ -> None)
             content)
      in
      texts (text :: acc) rest
  in
  texts [] messages
;;

let cli_failure_kind = function
  | Keeper_lane_cli_oneshot.Unknown_runtime { runtime_id } ->
    runtime_id, "unknown_runtime"
  | Keeper_lane_cli_oneshot.Not_an_official_client { runtime_id } ->
    runtime_id, "not_an_official_client"
  | Keeper_lane_cli_oneshot.Execution_failed { runtime_id; cause = _ } ->
    runtime_id, "execution_failed"
  | Keeper_lane_cli_oneshot.Invalid_json_output { runtime_id; detail = _ } ->
    runtime_id, "invalid_json_output"
  | Keeper_lane_cli_oneshot.Invalid_domain_output { runtime_id; detail = _ } ->
    runtime_id, "invalid_domain_output"
;;

let walk_cli_tail ?cli_runner ~base_path ~cli_slots ~request ~schema ~requirement () =
  match cli_slots with
  | [] -> Error Cli_tail_undeclared
  | _ :: _ ->
    (match cli_prompt request.messages with
     | Error unfit -> Error (Cli_tail_unfit unfit)
     | Ok prompt ->
       (* The runner reads an empty system prompt as none. *)
       let system_prompt =
         match request.system_prompt with
         | Some system_prompt -> system_prompt
         | None -> ""
       in
       (* [Json_syntax], as on the HTTP slots: this lane checks only required
          structure before the extension's full schema validation. *)
       Keeper_lane_cli_oneshot.walk
         ?runner:cli_runner
         ~base_dir:base_path
         ~cli_slots
         ~system_prompt
         ~requirement
         ~prompt
         ~validate:(fun output ->
           match required_shape_issue ~at:"$" schema output with
           | None -> Ok output
           | Some issue -> Error (output_shape_issue_to_string issue))
         ~on_failure:(fun failure ->
           let runtime_id, kind = cli_failure_kind failure in
           Log.Server.warn "browser_stagehand: cli slot %s failed (%s)" runtime_id kind)
         ()
       |> Result.map (fun (_runtime_id, output) -> output)
       |> Result.map_error (fun failures -> Cli_tail_exhausted failures))
;;

let serve ?cli_runner ~net ~clock ~base_path ~resolve_lane params =
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
  let requirement =
    Exact.make_output_requirement ~schema ~minimum_guarantee:Exact.Json_syntax
  in
  (* The CLI tail runs after every HTTP slot failed, or alone when the lane
     admitted none. *)
  let cli_tail ~http_failure ~rejected_http_outputs =
    match
      walk_cli_tail ?cli_runner ~base_path ~cli_slots:lane.cli_slots ~request ~schema ~requirement ()
    with
    | Ok output -> Ok (answer_of_cli_output output)
    | Error cli_tail ->
      Error (Generation_failed { http_failure; rejected_http_outputs; cli_tail })
  in
  match lane.http_slots with
  | [] -> cli_tail ~http_failure:None ~rejected_http_outputs:[]
  | first_slot :: other_slots ->
    let* attempt =
      start_flow ~first_slot ~other_slots ~messages:(exact_messages request) ~requirement
      |> Result.map_error (fun failure -> Flow_not_started failure)
    in
    let accept success =
      match required_shape_issue ~at:"$" schema (Exact.flow_success_output success).output with
      | None -> Exact.Accept success
      | Some issue -> Exact.Reject_and_advance issue
    in
    let rejection_of_receipt receipt =
      let visit = Exact.flow_success_candidate receipt.Exact.transport_success in
      { slot_id = visit.visit.identity.candidate_id; issue = receipt.rejection }
    in
    (match
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
     | Error (Exact.Flow_execution_terminal { cause; prior_rejections }) ->
       cli_tail ~http_failure:(Some cause)
         ~rejected_http_outputs:(List.map rejection_of_receipt prior_rejections)
     | Error (Exact.Flow_semantic_candidates_exhausted { rejections; _ }) ->
       cli_tail ~http_failure:None
         ~rejected_http_outputs:(List.map rejection_of_receipt
           (rejections.first :: rejections.rest)))
;;

let create ?cli_runner ~net ~clock ~base_path ~resolve_lane params
  : (Yojson.Safe.t, Wire.rpc_error) result
  =
  match serve ?cli_runner ~net ~clock ~base_path ~resolve_lane params with
  | Ok answer -> Ok answer
  | Error refusal ->
    Log.Server.warn "browser_stagehand: llm.generate refused (%s)" (refusal_kind refusal);
    Error (refusal_to_rpc_error refusal)
;;
