module Types = Llm_provider.Types

let ( let* ) = Result.bind
let ( let+ ) value f = Result.map f value
let content_to_yojson block = Checkpoint_codec.wire_content_block_to_json block

let validate_json ~context json =
  Execution_json.validate ~context json
  |> Result.map_error Execution_json.validation_error_to_string
;;

let content_of_yojson json =
  let decoded =
    try
      Checkpoint_codec.wire_content_block_of_json_strict json
      |> Result.map_error Error.to_string
    with
    | exn ->
      Llm_provider.Reserved_exn.reraise_if_reserved exn;
      Error ("provider response content decoding failed: " ^ Printexc.to_string exn)
  in
  let* block = decoded in
  let canonical = content_to_yojson block in
  if Yojson.Safe.equal json canonical
  then Ok block
  else Error "provider response content is not in canonical closed form"
;;

let optional_json value encode = Execution_json.option_json (Option.map encode value)

let response_to_yojson (response : Types.api_response) =
  `Assoc
    [ "id", `String response.id
    ; "model", `String response.model
    ; "stop_reason", `String (Types.stop_reason_to_string response.stop_reason)
    ; "content", `List (List.map content_to_yojson response.content)
    ; "usage", optional_json response.usage Types.api_usage_to_yojson
    ; "telemetry", optional_json response.telemetry Types.inference_telemetry_to_yojson
    ]
;;

let optional_field name decode fields =
  let* json = Execution_json.field name fields in
  match json with
  | `Null -> Ok None
  | value ->
    let+ decoded = decode value in
    Some decoded
;;

let response_of_yojson json =
  let* () = validate_json ~context:"provider response snapshot" json in
  let* fields =
    Execution_json.object_fields
      ~context:"provider response snapshot"
      ~required:[ "id"; "model"; "stop_reason"; "content"; "usage"; "telemetry" ]
      ~optional:[]
      json
  in
  let* id = Execution_json.string_field "id" fields in
  let* model = Execution_json.string_field "model" fields in
  let* stop_reason_wire = Execution_json.string_field "stop_reason" fields in
  let stop_reason = Types.stop_reason_of_string stop_reason_wire in
  let* () =
    if String.equal (Types.stop_reason_to_string stop_reason) stop_reason_wire
    then Ok ()
    else Error "provider response stop_reason is not canonical"
  in
  let* content_json = Execution_json.field "content" fields in
  let* content =
    match content_json with
    | `List blocks ->
      List.fold_left
        (fun accumulated block ->
           let* accumulated = accumulated in
           let+ block = content_of_yojson block in
           block :: accumulated)
        (Ok [])
        blocks
      |> Result.map List.rev
    | _ -> Error "provider response content must be an array"
  in
  let* usage = optional_field "usage" Types.api_usage_of_yojson fields in
  let* telemetry =
    optional_field "telemetry" Types.inference_telemetry_of_yojson fields
  in
  Ok { Types.id; model; unreadable_tool_uses = []; stop_reason; content; usage; telemetry }
;;

(* ── Admission ─────────────────────────────────────────────── *)

type admission =
  { source_map : Hooks.admitted_tool_source_map
  ; unavailable_names : string list
  ; unreadable : Types.unreadable_tool_use list
  }

type t =
  { response : Types.api_response
  ; admission : admission
  }

let name_resolution_to_yojson = function
  | Hooks.Registered_name -> `Assoc [ "kind", `String "registered" ]
  | Hooks.Recovered_name { tool_call_id; provider_name; registered_name } ->
    `Assoc
      [ "kind", `String "recovered"
      ; "tool_call_id", `String tool_call_id
      ; "provider_name", `String provider_name
      ; "registered_name", `String registered_name
      ]
;;

let name_resolution_of_yojson json =
  let* fields =
    Execution_json.object_fields
      ~context:"tool name resolution"
      ~required:[ "kind" ]
      ~optional:[ "tool_call_id"; "provider_name"; "registered_name" ]
      json
  in
  let* kind = Execution_json.string_field "kind" fields in
  match kind, fields with
  | "registered", [ _ ] -> Ok Hooks.Registered_name
  | "recovered", _ ->
    let* tool_call_id = Execution_json.string_field "tool_call_id" fields in
    let* provider_name = Execution_json.string_field "provider_name" fields in
    let+ registered_name = Execution_json.string_field "registered_name" fields in
    Hooks.Recovered_name { tool_call_id; provider_name; registered_name }
  | "registered", _ -> Error "registered tool name resolution carries extra fields"
  | other, _ -> Error ("unknown tool name resolution kind: " ^ other)
;;

let source_to_yojson (source : Hooks.admitted_tool_use_source) =
  `Assoc
    [ "planned_index", `Int source.planned_index
    ; "source_tool_use_ordinal", `Int source.source_tool_use_ordinal
    ; "name_resolution", name_resolution_to_yojson source.name_resolution
    ]
;;

let source_of_yojson json =
  let* fields =
    Execution_json.object_fields
      ~context:"admitted tool source"
      ~required:[ "planned_index"; "source_tool_use_ordinal"; "name_resolution" ]
      ~optional:[]
      json
  in
  let* planned_index = Execution_json.int_field "planned_index" fields in
  let* source_tool_use_ordinal =
    Execution_json.int_field "source_tool_use_ordinal" fields
  in
  let* resolution_json = Execution_json.field "name_resolution" fields in
  let+ name_resolution = name_resolution_of_yojson resolution_json in
  { Hooks.planned_index; source_tool_use_ordinal; name_resolution }
;;

let list_of_yojson ~context decode = function
  | `List items ->
    List.fold_left
      (fun accumulated item ->
         let* accumulated = accumulated in
         let+ decoded = decode item in
         decoded :: accumulated)
      (Ok [])
      items
    |> Result.map List.rev
  | _ -> Error (context ^ " must be an array")
;;

let string_of_yojson = function
  | `String value -> Ok value
  | _ -> Error "refused tool name must be a string"
;;

let admission_to_yojson admission =
  `Assoc
    [ ( "admitted_tool_sources"
      , `List (List.map source_to_yojson admission.source_map.admitted_tool_sources) )
    ; "source_tool_use_count", `Int admission.source_map.source_tool_use_count
    ; ( "unavailable_names"
      , `List (List.map (fun name -> `String name) admission.unavailable_names) )
    ; ( "unreadable"
      , `List (List.map Types.unreadable_tool_use_to_yojson admission.unreadable) )
    ]
;;

let admission_of_yojson json =
  let* fields =
    Execution_json.object_fields
      ~context:"tool admission"
      ~required:
        [ "admitted_tool_sources"
        ; "source_tool_use_count"
        ; "unavailable_names"
        ; "unreadable"
        ]
      ~optional:[]
      json
  in
  let* sources_json = Execution_json.field "admitted_tool_sources" fields in
  let* admitted_tool_sources =
    list_of_yojson ~context:"admitted_tool_sources" source_of_yojson sources_json
  in
  let* source_tool_use_count = Execution_json.int_field "source_tool_use_count" fields in
  let* names_json = Execution_json.field "unavailable_names" fields in
  let* unavailable_names =
    list_of_yojson ~context:"unavailable_names" string_of_yojson names_json
  in
  let* unreadable_json = Execution_json.field "unreadable" fields in
  let+ unreadable =
    list_of_yojson
      ~context:"unreadable"
      (fun call ->
         Types.unreadable_tool_use_of_yojson call
         |> Result.map_error (fun detail -> "unreadable tool use: " ^ detail))
      unreadable_json
  in
  { source_map = { Hooks.admitted_tool_sources; source_tool_use_count }
  ; unavailable_names
  ; unreadable
  }
;;

let to_yojson snapshot =
  `Assoc
    [ "response", response_to_yojson snapshot.response
    ; "admission", admission_to_yojson snapshot.admission
    ]
;;

(* [Execution_event.node_update] derives [show]; the record prints as its
   wire JSON so the printed form is the journaled form. *)
let pp fmt snapshot = Yojson.Safe.pretty_print fmt (to_yojson snapshot)

let of_yojson json =
  let* fields =
    Execution_json.object_fields
      ~context:"provider response snapshot"
      ~required:[ "response"; "admission" ]
      ~optional:[]
      json
  in
  let* response_json = Execution_json.field "response" fields in
  let* response = response_of_yojson response_json in
  let* admission_json = Execution_json.field "admission" fields in
  let+ admission = admission_of_yojson admission_json in
  { response; admission }
;;

(* The admission must describe the response it is stored with. A record that
   does not would seal a resumed turn's tool occurrences against the wrong
   provider calls, so it is refused before it becomes durable. *)
let validate_admission (response : Types.api_response) admission =
  let sources = admission.source_map.admitted_tool_sources in
  let count = admission.source_map.source_tool_use_count in
  let admitted_tool_uses =
    List.fold_left
      (fun count (block : Types.content_block) ->
         match block with
         | Types.ToolUse _ -> count + 1
         | Types.Text _
         | Types.Thinking _
         | Types.ReasoningDetails _
         | Types.RedactedThinking _
         | Types.ToolResult _
         | Types.ToolReference _
         | Types.Image _
         | Types.Document _
         | Types.Audio _ -> count)
      0
      response.content
  in
  let source_ordinals =
    List.map (fun (source : Hooks.admitted_tool_use_source) -> source.source_tool_use_ordinal)
      sources
  in
  let unreadable_ordinals =
    List.map
      (fun (call : Types.unreadable_tool_use) -> call.tool_use_ordinal)
      admission.unreadable
  in
  let ordinals = source_ordinals @ unreadable_ordinals in
  let distinct values =
    List.length (List.sort_uniq Int.compare values) = List.length values
  in
  let* () =
    if List.length sources = admitted_tool_uses
    then Ok ()
    else Error "tool admission sources do not match the admitted ToolUse blocks"
  in
  let* () =
    if List.for_all2
         (fun index (source : Hooks.admitted_tool_use_source) ->
            source.planned_index = index)
         (List.init (List.length sources) Fun.id)
         sources
    then Ok ()
    else Error "tool admission planned indices are not in planned order"
  in
  let* () =
    if distinct ordinals
       && List.for_all (fun ordinal -> ordinal >= 0 && ordinal < count) ordinals
    then Ok ()
    else Error "tool admission ordinals are not distinct places among the tool calls"
  in
  if count
     = List.length sources
       + List.length admission.unavailable_names
       + List.length admission.unreadable
  then Ok ()
  else Error "tool admission count does not equal admitted plus refused calls"
;;

(* The recorded response is the one tool admission kept. Admission answers the
   model about each unreadable tool call and keeps none of them in the
   response; the calls themselves are kept in [admission.unreadable]. *)
let validate snapshot =
  let* () =
    match snapshot.response.unreadable_tool_uses with
    | [] -> Ok ()
    | _ :: _ ->
      Error "provider response snapshot still carries unreadable tool uses"
  in
  let* () = validate_admission snapshot.response snapshot.admission in
  let encoded = to_yojson snapshot in
  let* () = validate_json ~context:"provider response snapshot" encoded in
  let* decoded = of_yojson encoded in
  if snapshot = decoded
  then Ok ()
  else Error "provider response snapshot does not round-trip exactly"
;;
