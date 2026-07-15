type t =
  { request_id : string
  ; keeper_name : string
  ; generation : int
  ; turn : int
  ; runtime_id : string
  ; meta : Keeper_meta_contract.keeper_meta
  ; tool_results : Yojson.Safe.t list
  ; librarian_messages : Agent_sdk.Types.message list
  ; deliberation_execution : Yojson.Safe.t option
  }

let schema_version = 1
let ( let* ) = Result.bind

let request_id request = request.request_id
let keeper_name request = request.keeper_name
let generation request = request.generation
let turn request = request.turn
let runtime_id request = request.runtime_id
let meta request = request.meta
let tool_results request = request.tool_results
let librarian_messages request = request.librarian_messages
let deliberation_execution request = request.deliberation_execution

let validate_fields ~context ~expected fields =
  let rec loop seen = function
    | [] ->
      (match List.find_opt (fun name -> not (List.mem name seen)) expected with
       | None -> Ok ()
       | Some name -> Error (Printf.sprintf "%s is missing field %S" context name))
    | (name, _) :: rest ->
      if List.mem name seen then
        Error (Printf.sprintf "%s has duplicate field %S" context name)
      else if not (List.mem name expected) then
        Error (Printf.sprintf "%s has unknown field %S" context name)
      else
        loop (name :: seen) rest
  in
  loop [] fields
;;

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "memory work request is missing field %S" name)
;;

let string_field name fields =
  let* value = field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "memory work request field %S must be a string" name)
;;

let int_field name fields =
  let* value = field name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "memory work request field %S must be an integer" name)
;;

let rec normalize_json = function
  | `Assoc fields ->
    fields
    |> List.map (fun (name, value) -> name, normalize_json value)
    |> List.stable_sort (fun (left, _) (right, _) -> String.compare left right)
    |> fun fields -> `Assoc fields
  | `List values -> `List (List.map normalize_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value -> value
;;

let body_to_json
      ~keeper_name
      ~generation
      ~turn
      ~runtime_id
      ~meta
      ~tool_results
      ~librarian_messages
      ~deliberation_execution
  =
  `Assoc
    [ "keeper_name", `String keeper_name
    ; "generation", `Int generation
    ; "turn", `Int turn
    ; "runtime_id", `String runtime_id
    ; "meta", Keeper_meta_json.meta_to_json meta
    ; "tool_results", `List tool_results
    ; ( "librarian_messages"
      , `List (List.map Keeper_context_core.message_to_json librarian_messages) )
    ; ( "deliberation_execution"
      , Option.value ~default:`Null deliberation_execution )
    ]
;;

let request_id_of_body body =
  body
  |> normalize_json
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let validate_snapshot
      ~keeper_name
      ~generation
      ~turn
      ~runtime_id
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~tool_results
      ~deliberation_execution
  =
  if String.trim keeper_name = "" then
    Error "memory work keeper_name must not be empty"
  else if String.trim runtime_id = "" then
    Error "memory work runtime_id must not be empty"
  else if generation < 0 then
    Error "memory work generation must not be negative"
  else if turn < 0 then
    Error "memory work turn must not be negative"
  else if not (String.equal keeper_name meta.name) then
    Error "memory work keeper_name does not match its meta snapshot"
  else if meta.runtime.generation <> generation then
    Error "memory work generation does not match its meta snapshot"
  else if not (List.for_all (function `Assoc _ -> true | _ -> false) tool_results) then
    Error "memory work tool_results must contain only typed JSON objects"
  else
    match deliberation_execution with
    | None | Some (`Assoc _) -> Ok ()
    | Some _ -> Error "memory work deliberation_execution must be a JSON object"
;;

let make
      ~keeper_name
      ~generation
      ~turn
      ~runtime_id
      ~meta
      ~tool_results
      ~librarian_messages
      ~deliberation_execution
  =
  let* () =
    validate_snapshot
      ~keeper_name
      ~generation
      ~turn
      ~runtime_id
      ~meta
      ~tool_results
      ~deliberation_execution
  in
  let body =
    body_to_json
      ~keeper_name
      ~generation
      ~turn
      ~runtime_id
      ~meta
      ~tool_results
      ~librarian_messages
      ~deliberation_execution
  in
  Ok
    { request_id = request_id_of_body body
    ; keeper_name
    ; generation
    ; turn
    ; runtime_id
    ; meta
    ; tool_results
    ; librarian_messages
    ; deliberation_execution
    }
;;

let body_of_request request =
  body_to_json
    ~keeper_name:request.keeper_name
    ~generation:request.generation
    ~turn:request.turn
    ~runtime_id:request.runtime_id
    ~meta:request.meta
    ~tool_results:request.tool_results
    ~librarian_messages:request.librarian_messages
    ~deliberation_execution:request.deliberation_execution
;;

let to_json request =
  `Assoc
    [ "schema_version", `Int schema_version
    ; "request_id", `String request.request_id
    ; "body", body_of_request request
    ]
;;

let list_field name fields =
  let* value = field name fields in
  match value with
  | `List values -> Ok values
  | _ -> Error (Printf.sprintf "memory work request field %S must be a list" name)
;;

let decode_message value =
  try
    let message = Keeper_context_core.message_of_json value in
    match value with
    | `Assoc fields ->
      (match List.assoc_opt "metadata" fields with
       | None -> Ok message
       | Some (`Assoc metadata) -> Ok { message with metadata }
       | Some _ -> Error "librarian message metadata must be a JSON object")
    | _ -> Error "librarian message must be a JSON object"
  with
  | exn -> Error (Printf.sprintf "invalid librarian message: %s" (Printexc.to_string exn))
;;

let decode_messages values =
  List.fold_right
    (fun value result ->
       let* rest = result in
       let* message = decode_message value in
       Ok (message :: rest))
    values
    (Ok [])
;;

let of_body_json = function
  | `Assoc fields ->
    let expected =
      [ "keeper_name"; "generation"; "turn"; "runtime_id"; "meta"
      ; "tool_results"; "librarian_messages"; "deliberation_execution"
      ]
    in
    let* () = validate_fields ~context:"memory work request body" ~expected fields in
    let* keeper_name = string_field "keeper_name" fields in
    let* generation = int_field "generation" fields in
    let* turn = int_field "turn" fields in
    let* runtime_id = string_field "runtime_id" fields in
    let* meta_json = field "meta" fields in
    let* meta = Keeper_meta_json.meta_of_json meta_json in
    let* tool_results = list_field "tool_results" fields in
    let* message_values = list_field "librarian_messages" fields in
    let* librarian_messages = decode_messages message_values in
    let* deliberation_json = field "deliberation_execution" fields in
    let deliberation_execution =
      match deliberation_json with
      | `Null -> Ok None
      | `Assoc _ as json -> Ok (Some json)
      | _ -> Error "memory work deliberation_execution must be an object or null"
    in
    let* deliberation_execution = deliberation_execution in
    make
      ~keeper_name
      ~generation
      ~turn
      ~runtime_id
      ~meta
      ~tool_results
      ~librarian_messages
      ~deliberation_execution
  | _ -> Error "memory work request body must be a JSON object"
;;

let of_json = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"memory work request"
        ~expected:[ "schema_version"; "request_id"; "body" ]
        fields
    in
    let* encoded_schema = int_field "schema_version" fields in
    if encoded_schema <> schema_version then
      Error (Printf.sprintf "unsupported memory work schema_version %d" encoded_schema)
    else
      let* encoded_id = string_field "request_id" fields in
      let* body = field "body" fields in
      let* request = of_body_json body in
      if String.equal encoded_id request.request_id then
        Ok request
      else
        Error "memory work request_id does not match its canonical body"
  | _ -> Error "memory work request must be a JSON object"
;;
