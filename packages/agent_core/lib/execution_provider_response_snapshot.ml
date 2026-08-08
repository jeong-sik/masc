module Types = Llm_provider.Types

let ( let* ) = Result.bind
let ( let+ ) value f = Result.map f value
let content_to_yojson block = Checkpoint_codec.checkpoint_content_block_to_json block

let content_of_yojson json =
  let decoded =
    try
      Checkpoint_codec.content_block_of_json_strict json
      |> Result.map_error Error.to_string
    with
    | exn ->
      Llm_provider.Reserved_exn.reraise_if_reserved exn;
      Error ("provider response content decoding failed: " ^ Printexc.to_string exn)
  in
  let* block = decoded in
  let canonical =
    try Ok (content_to_yojson block) with
    | exn ->
      Llm_provider.Reserved_exn.reraise_if_reserved exn;
      Error ("provider response content encoding failed: " ^ Printexc.to_string exn)
  in
  let* canonical = canonical in
  if Yojson.Safe.equal json canonical
  then Ok block
  else Error "provider response content is not in canonical closed form"
;;

let optional_json value encode = Execution_json.option_json (Option.map encode value)

let to_yojson (response : Types.api_response) =
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

let of_yojson json =
  let* () = Execution_json.validate ~context:"provider response snapshot" json in
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
  Ok { Types.id; model; stop_reason; content; usage; telemetry }
;;

let validate response =
  let encoded =
    try Ok (to_yojson response) with
    | exn ->
      Llm_provider.Reserved_exn.reraise_if_reserved exn;
      Error ("provider response snapshot encoding failed: " ^ Printexc.to_string exn)
  in
  let* encoded = encoded in
  let* () = Execution_json.validate ~context:"provider response snapshot" encoded in
  let* decoded = of_yojson encoded in
  if response = decoded
  then Ok ()
  else Error "provider response snapshot does not round-trip exactly"
;;
