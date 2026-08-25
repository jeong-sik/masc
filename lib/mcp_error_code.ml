type t =
  | Parse_error
  | Invalid_request
  | Method_not_found
  | Invalid_params
  | Internal_error
  | Auth_error
  | Not_ready
  | Provider_timeout
  | Tool_dispatch_failure
  | Backpressure_shed
  | Session_evicted
  | Unsupported_protocol_version
  | Quiet of { reason : string ; recovered : bool }

let to_wire_code = function
  | Parse_error -> -32700
  | Invalid_request -> -32600
  | Method_not_found -> -32601
  | Invalid_params -> -32602
  | Internal_error -> -32603
  | Auth_error -> -32001
  | Not_ready -> -32002
  | Provider_timeout -> -32003
  | Tool_dispatch_failure -> -32004
  | Backpressure_shed -> -32005
  | Session_evicted -> -32006
  (* Fixed by MCP revision 2026-07-28, not chosen by this server: clients pin
     on -32022 to tell a modern server from a legacy one. *)
  | Unsupported_protocol_version -> -32022
  | Quiet _ -> -32099

let of_wire_code = function
  | -32700 -> Some Parse_error
  | -32600 -> Some Invalid_request
  | -32601 -> Some Method_not_found
  | -32602 -> Some Invalid_params
  | -32603 -> Some Internal_error
  | -32001 -> Some Auth_error
  | -32002 -> Some Not_ready
  | -32003 -> Some Provider_timeout
  | -32004 -> Some Tool_dispatch_failure
  | -32005 -> Some Backpressure_shed
  | -32006 -> Some Session_evicted
  | -32022 -> Some Unsupported_protocol_version
  | _ -> None

let to_wire_message_default = function
  | Parse_error -> "Parse error"
  | Invalid_request -> "Invalid Request"
  | Method_not_found -> "Method not found"
  | Invalid_params -> "Invalid params"
  | Internal_error -> "Internal error"
  | Auth_error -> "Unauthorized"
  | Not_ready -> "Server is starting up, not ready yet"
  | Provider_timeout -> "Upstream provider timed out"
  | Tool_dispatch_failure -> "Tool dispatch failed"
  | Backpressure_shed -> "Backpressure shed; resume via Last-Event-ID"
  | Session_evicted -> "Session evicted by server policy"
  (* Verbatim from the MCP 2026-07-28 example response. *)
  | Unsupported_protocol_version -> "Unsupported protocol version"
  | Quiet { reason ; _ } -> reason

(* JSON-RPC 2.0 §5: a response may carry a null id only when the request
   id could not be determined — a parse failure or a malformed request
   object. Every other code answers a request whose id was read, so the
   arms are listed rather than caught, and a new code has to choose here. *)
let allows_null_request_id : t -> bool = function
  | Parse_error -> true
  | Invalid_request -> true
  | Method_not_found -> false
  | Invalid_params -> false
  | Internal_error -> false
  | Auth_error -> false
  | Not_ready -> false
  | Provider_timeout -> false
  | Tool_dispatch_failure -> false
  | Backpressure_shed -> false
  | Session_evicted -> false
  (* The version is read from the [MCP-Protocol-Version] header, so the
     rejection happens before the JSON-RPC body — and the request id — has
     been parsed. That is exactly the §5 case a null id is for. *)
  | Unsupported_protocol_version -> true
  | Quiet _ -> false
;;

let to_http_status : t -> Httpun.Status.t = function
  | Parse_error -> `Bad_request
  | Invalid_request -> `Bad_request
  | Method_not_found -> `Not_found
  | Invalid_params -> `Bad_request
  | Internal_error -> `Internal_server_error
  | Auth_error -> `Unauthorized
  | Not_ready -> `Service_unavailable
  | Provider_timeout -> `Gateway_timeout
  | Tool_dispatch_failure -> `Internal_server_error
  | Backpressure_shed -> `Too_many_requests
  | Session_evicted -> `Gone
  (* 4xx is what MCP 2026-07-28 Backward Compatibility has clients inspect;
     the body, not the status, is what marks the server as modern. *)
  | Unsupported_protocol_version -> `Bad_request
  | Quiet _ -> `OK

let all =
  [
    Parse_error;
    Invalid_request;
    Method_not_found;
    Invalid_params;
    Internal_error;
    Auth_error;
    Not_ready;
    Provider_timeout;
    Tool_dispatch_failure;
    Backpressure_shed;
    Session_evicted;
    Unsupported_protocol_version;
    Quiet { reason = "<exemplar>"; recovered = false };
  ]

let jsonrpc_error_body (t : t) ~(message : string) : string =
  Printf.sprintf
    {|{"jsonrpc":"2.0","error":{"code":%d,"message":"%s"},"id":null}|}
    (to_wire_code t)
    (String.escaped message)

let unsupported_protocol_version_body ~(requested : string)
    ~(supported : string list) : string =
  Yojson.Safe.to_string
    (`Assoc
       [ ("jsonrpc", `String "2.0")
       ; ( "error"
         , `Assoc
             [ ("code", `Int (to_wire_code Unsupported_protocol_version))
             ; ( "message"
               , `String
                   (to_wire_message_default Unsupported_protocol_version) )
             ; ( "data"
               , `Assoc
                   [ ( "supported"
                     , `List (List.map (fun v -> `String v) supported) )
                   ; ("requested", `String requested)
                   ] )
             ] )
       ; ("id", `Null)
       ])

let pp fmt = function
  | Parse_error -> Format.pp_print_string fmt "Parse_error"
  | Invalid_request -> Format.pp_print_string fmt "Invalid_request"
  | Method_not_found -> Format.pp_print_string fmt "Method_not_found"
  | Invalid_params -> Format.pp_print_string fmt "Invalid_params"
  | Internal_error -> Format.pp_print_string fmt "Internal_error"
  | Auth_error -> Format.pp_print_string fmt "Auth_error"
  | Not_ready -> Format.pp_print_string fmt "Not_ready"
  | Provider_timeout -> Format.pp_print_string fmt "Provider_timeout"
  | Tool_dispatch_failure -> Format.pp_print_string fmt "Tool_dispatch_failure"
  | Backpressure_shed -> Format.pp_print_string fmt "Backpressure_shed"
  | Session_evicted -> Format.pp_print_string fmt "Session_evicted"
  | Unsupported_protocol_version ->
      Format.pp_print_string fmt "Unsupported_protocol_version"
  | Quiet { reason ; recovered } ->
      Format.fprintf fmt "Quiet { reason = %S ; recovered = %b }" reason
        recovered
