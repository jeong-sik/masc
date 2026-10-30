let sdk_owned_methods =
  [
    "ping";
  ]

let handles_method method_ =
  List.mem method_ sdk_owned_methods

let dispatch_ping ~id =
  Some (Mcp_transport_protocol.make_response ~id (`Assoc []))

let dispatch_request
    ~handle_call_tool_eio:_
    ~state:_
    ~profile:_
    ~sw:_
    ~clock:_
    ?mcp_session_id:_
    ?auth_token:_
    (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
      let id =
        match List.assoc_opt "id" fields with
        | Some id -> id
        | None -> `Null
      in
      let method_ =
        match List.assoc_opt "method" fields with
        | Some (`String m) -> m
        | _ -> ""
      in
      (match method_ with
      | "ping" -> dispatch_ping ~id
      | _ -> None)
  | _ -> None
