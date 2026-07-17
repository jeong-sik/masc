type t =
  | External_mcp of
      { request_id : Mcp_transport_protocol.request_id
      ; session_id : string
      }

type error = Invalid_mcp_session_id

let external_mcp ~request_id ~session_id =
  if not (Mcp_session.is_valid session_id)
  then Error Invalid_mcp_session_id
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

let equal left right =
  match left, right with
  | ( External_mcp { request_id = left_id; session_id = left_session }
    , External_mcp { request_id = right_id; session_id = right_session } ) ->
    String.equal left_session right_session
    && Mcp_transport_protocol.request_id_equal left_id right_id
;;

let error_to_string = function
  | Invalid_mcp_session_id ->
    "external MCP tool invocation requires a valid stable MCP session id"
;;
