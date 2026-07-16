type t =
  | External_mcp of
      { request_id : Mcp_transport_protocol.request_id
      ; session_id : string
      }

type error = Empty_mcp_session_id

type decode_error =
  | Expected_object
  | Unknown_field of string
  | Duplicate_field of string
  | Missing_field of string
  | Expected_string of string
  | Invalid_source of string
  | Invalid_request_id of Mcp_transport_protocol.request_id_error
  | Invalid_identity of error

let external_mcp ~request_id ~session_id =
  if String.equal (String.trim session_id) ""
  then Error Empty_mcp_session_id
  else Ok (External_mcp { request_id; session_id })
;;

let to_yojson = function
  | External_mcp { request_id; session_id } ->
    `Assoc
      [ "source", `String "external_mcp"
      ; "session_id", `String session_id
      ; "request_id", Mcp_transport_protocol.request_id_to_yojson request_id
      ]
;;

let of_yojson = function
  | `Assoc fields ->
    let allowed = [ "source"; "session_id"; "request_id" ] in
    let rec validate seen = function
      | [] -> Ok ()
      | (name, _) :: rest when not (List.mem name allowed) -> Error (Unknown_field name)
      | (name, _) :: _ when List.mem name seen -> Error (Duplicate_field name)
      | (name, _) :: rest -> validate (name :: seen) rest
    in
    let required name =
      match List.assoc_opt name fields with
      | Some value -> Ok value
      | None -> Error (Missing_field name)
    in
    let ( let* ) = Result.bind in
    let* () = validate [] fields in
    let* source = required "source" in
    let* session_id = required "session_id" in
    let* request_id = required "request_id" in
    let* () =
      match source with
      | `String "external_mcp" -> Ok ()
      | `String value -> Error (Invalid_source value)
      | _ -> Error (Expected_string "source")
    in
    let* session_id =
      match session_id with
      | `String value -> Ok value
      | _ -> Error (Expected_string "session_id")
    in
    let* request_id =
      Mcp_transport_protocol.request_id_of_yojson request_id
      |> Result.map_error (fun error -> Invalid_request_id error)
    in
    external_mcp ~request_id ~session_id
    |> Result.map_error (fun error -> Invalid_identity error)
  | _ -> Error Expected_object
;;

let equal left right =
  match left, right with
  | ( External_mcp { request_id = left_id; session_id = left_session }
    , External_mcp { request_id = right_id; session_id = right_session } ) ->
    String.equal left_session right_session
    && Mcp_transport_protocol.request_id_equal left_id right_id
;;

let error_to_string = function
  | Empty_mcp_session_id ->
    "external MCP tool invocation requires a non-empty stable session id"
;;

let decode_error_to_string = function
  | Expected_object -> "tool invocation identity must be a JSON object"
  | Unknown_field name ->
    Printf.sprintf "tool invocation identity has unknown field %S" name
  | Duplicate_field name ->
    Printf.sprintf "tool invocation identity has duplicate field %S" name
  | Missing_field name ->
    Printf.sprintf "tool invocation identity is missing field %S" name
  | Expected_string name ->
    Printf.sprintf "tool invocation identity field %S must be a string" name
  | Invalid_source source ->
    Printf.sprintf "tool invocation identity has invalid source %S" source
  | Invalid_request_id error ->
    Mcp_transport_protocol.request_id_error_to_string error
  | Invalid_identity error -> error_to_string error
;;
