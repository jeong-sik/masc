(** See the interface. *)

module P = Mcp_transport_protocol

type t =
  | Answer of Yojson.Safe.t
  | Notification of P.jsonrpc_request
  | Request of
      { id : Yojson.Safe.t
      ; message : Yojson.Safe.t
      ; request : P.jsonrpc_request
      ; protocol : P.request_protocol
      }

let error ?data ~id (code : Mcp_error_code.t) message =
  P.make_error ?data ~id (Mcp_error_code.to_wire_code code) message
;;

let protocol_error ~id = function
  | P.Invalid_request_meta message -> error ~id Mcp_error_code.Invalid_params message
  | P.Unsupported_request_version requested ->
    error
      ~id
      ~data:
        (`Assoc
            [ ( "supported"
              , `List (List.map (fun version -> `String version) P.supported_protocol_versions) )
            ; "requested", `String requested
            ])
      Mcp_error_code.Unsupported_protocol_version
      "Unsupported protocol version"
;;

let removed_from_stateless_protocol = function
  | "initialize"
  | "notifications/initialized"
  | "ping"
  | "resources/subscribe"
  | "resources/unsubscribe"
  | "logging/setLevel" -> true
  | _ -> false
;;

let takes_continuation = function
  | "tools/call" | "resources/read" | "prompts/get" -> true
  | _ -> false
;;

let admit_request ~method_allowed ~endpoint ~message (request : P.jsonrpc_request) =
  let id = P.get_id request in
  if not (method_allowed request.method_)
  then
    if P.is_notification request
    then Answer `Null
    else
      Answer
        (error
           ~id
           Mcp_error_code.Method_not_found
           (Printf.sprintf "%s is not available on the %s endpoint" request.method_ endpoint))
  else if P.is_notification request
  then Notification request
  else if not (P.is_valid_request_id id)
  then
    Answer
      (error
         ~id:`Null
         Mcp_error_code.Invalid_request
         "Invalid Request: MCP id must be a string or integer")
  else (
    match
      P.classify_request_protocol
        ~require_stateless:false
        ~method_:request.method_
        ~params:request.params
    with
    | Error failure -> Answer (protocol_error ~id failure)
    | Ok (P.Stateless_protocol (_ : string)) when removed_from_stateless_protocol request.method_
      ->
      Answer (error ~id Mcp_error_code.Method_not_found ("Method not found: " ^ request.method_))
    | Ok (P.Stateless_protocol (_ : string))
      when takes_continuation request.method_ && P.request_has_continuation_fields request.params
      ->
      Answer
        (error
           ~id
           Mcp_error_code.Invalid_params
           "This server has no resumable request for the supplied continuation")
    | Ok ((P.Legacy_protocol | P.Stateless_protocol (_ : string)) as protocol) ->
      Request { id; message; request; protocol })
;;

let admit ~method_allowed ~endpoint text =
  match Yojson.Safe.from_string text with
  | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
  | exception exn ->
    (* Whatever the parser raises on text it cannot read is a parse error of
       the message, a stack exhausted by its nesting included. *)
    Answer
      (error
         ~id:`Null
         ~data:(`String (Printexc.to_string exn))
         Mcp_error_code.Parse_error
         "Parse error")
  | `List (_ : Yojson.Safe.t list) ->
    Answer
      (error
         ~id:`Null
         Mcp_error_code.Invalid_request
         "JSON-RPC batch requests are not supported on this MCP endpoint")
  | json ->
    if P.is_jsonrpc_response json
    then Answer `Null
    else if not (P.is_jsonrpc_v2 json)
    then
      Answer (error ~id:`Null Mcp_error_code.Invalid_request "Invalid Request: jsonrpc must be 2.0")
    else if not (P.has_unique_jsonrpc_fields json)
    then
      Answer
        (error ~id:`Null Mcp_error_code.Invalid_request "Invalid Request: duplicate JSON-RPC field")
    else (
      match P.jsonrpc_request_of_yojson json with
      | Error message ->
        Answer
          (error ~id:`Null ~data:(`String message) Mcp_error_code.Invalid_request "Invalid Request")
      | Ok request -> admit_request ~method_allowed ~endpoint ~message:json request)
;;
