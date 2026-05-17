(** Server_mcp_transport_http_respond — HTTP MCP error / not-ready /
    rate-limit response factories. *)

(** [safe_respond_with_string] guards [Httpun.Reqd.respond_with_string]
    against the [Failure "invalid state, currently handling error"] race
    that occurs when a client disconnects while a long OAS turn is in
    progress and httpun's error_handler has already started responding
    (2026-05-05 cycle9 FATAL incident). *)
let safe_respond_with_string reqd response body =
  (* #13102 follow-up: backtraces are enabled at process start in
     [bin/main_eio.ml] (Printexc.record_backtrace true), so the
     unexpected-exception arm attaches the backtrace whenever it is
     available.  The known-race arm (Failure path) keeps its compact
     one-line format because the failure mode is well-classified and
     the surrounding incident note already captures the diagnostic
     intent — adding a backtrace there would just churn parsers. *)
  try Httpun.Reqd.respond_with_string reqd response body
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Failure msg ->
      Log.Server.warn
        "[mcp-http] respond_with_string skipped (reqd invalid state; \
         2026-05-05 OAS cancel race): %s"
        msg
  | exn ->
      let backtrace = Printexc.get_backtrace () in
      let summary = Printexc.to_string exn in
      if String.trim backtrace = "" then
        Log.Server.warn
          "[mcp-http] respond_with_string unexpected exception: %s"
          summary
      else
        Log.Server.warn
          "[mcp-http] respond_with_string unexpected exception: %s\n%s"
          summary backtrace

let mcp_headers = Server_mcp_transport_http_headers.mcp_headers

let json_headers = Server_mcp_transport_http_headers.json_headers

let respond_mcp_auth_error ?(extra_headers = []) ~(deps : Server_mcp_transport_http_types.deps) request reqd ~session_id
    ~protocol_version msg =
  let origin = deps.get_origin request in
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ( "error",
            `Assoc
              [ ("code", `Int (-32001)); ("message", `String msg) ] );
        ])
  in
  let headers =
    Httpun.Headers.of_list
      ((("content-length", string_of_int (String.length body))
       :: ("www-authenticate", "Bearer")
       :: extra_headers)
      @ json_headers ~deps session_id protocol_version origin)
  in
  let response = Httpun.Response.create ~headers `Unauthorized in
  safe_respond_with_string reqd response body

let respond_mcp_internal_error ?(extra_headers = []) ~(deps : Server_mcp_transport_http_types.deps) request reqd
    ~session_id ~protocol_version msg =
  let origin = deps.get_origin request in
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ( "error",
            `Assoc
              [ ("code", `Int (-32603)); ("message", `String msg) ] );
        ])
  in
  let headers =
    Httpun.Headers.of_list
      ((("content-length", string_of_int (String.length body)) :: extra_headers)
      @ json_headers ~deps session_id protocol_version origin)
  in
  let response = Httpun.Response.create ~headers `Internal_server_error in
  safe_respond_with_string reqd response body

let respond_not_ready ~(deps : Server_mcp_transport_http_types.deps) request reqd =
  let origin = deps.get_origin request in
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("error",
           `Assoc
             [
               ("code", `Int (-32002));
               ("message", `String "Server is starting up, not ready yet");
             ]);
          ("id", `Null);
        ])
  in
  let headers =
    Httpun.Headers.of_list
      ([
         ("content-type", "application/json");
         ("content-length", string_of_int (String.length body));
         ("retry-after", "2");
       ]
      @ deps.cors_headers origin)
  in
  let response = Httpun.Response.create ~headers `Service_unavailable in
  safe_respond_with_string reqd response body

let respond_sse_rate_limited ~(deps : Server_mcp_transport_http_types.deps) ~origin ~session_id ~protocol_version
    ~reason ~retry_after_s reqd =
  let reason_label = Sse_reject_reason.to_label reason in
  Transport_metrics.inc_sse_reject ~reason:reason_label;
  let retry_after_s = Float.max retry_after_s 0.001 in
  let retry_after_header =
    retry_after_s |> Float.ceil |> int_of_float |> max 1 |> string_of_int
  in
  let body =
    `Assoc
      [
        ("error", `String "sse_connection_rate_limited");
        ("reason", `String reason_label);
        ("retry_after_seconds", `Float retry_after_s);
      ]
    |> Yojson.Safe.to_string
  in
  let headers =
    Httpun.Headers.of_list
      (("content-length", string_of_int (String.length body))
      :: ("retry-after", retry_after_header)
      :: json_headers ~deps session_id protocol_version origin)
  in
  let response = Httpun.Response.create ~headers `Too_many_requests in
  safe_respond_with_string reqd response body

let mcp_internal_error_json ?id msg =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", Option.value ~default:`Null id);
      ("error", `Assoc [ ("code", `Int (-32603)); ("message", `String msg) ]);
    ]

(* RFC-0098 — typed SSOT for transport-boundary error envelopes. The
   legacy factories above are intentionally untouched in PR-1 to
   guarantee byte-exact wire on existing call paths; PR-2 migrates
   them to delegations and documents the wire change (adding id:null
   per JSON-RPC 2.0 §5.1). *)
let respond_mcp_error ?(extra_headers = []) ?data ?id
    ~(deps : Server_mcp_transport_http_types.deps) request reqd ~session_id
    ~protocol_version ~(code : Mcp_error_code.t) msg =
  let origin = deps.get_origin request in
  let error_fields =
    let base =
      [
        ("code", `Int (Mcp_error_code.to_wire_code code));
        ("message", `String msg);
      ]
    in
    match data with Some d -> base @ [ ("data", d) ] | None -> base
  in
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          (* DET-OK: JSON-RPC response id is request-bound wire data; absent id maps to protocol null at this HTTP boundary. *)
          ("id", Option.value ~default:`Null id);
          ("error", `Assoc error_fields);
        ])
  in
  (* Constructors qualified explicitly (Mcp_error_code.Auth_error rather
     than bare Auth_error) so the match is robust to future loss of the
     [~(code : Mcp_error_code.t)] type annotation or to relocation of
     the function. Bare constructors would compile today via OCaml's
     type-directed disambiguation but the reviewer's defence-in-depth
     concern (PR #15759 codex P1) is well-taken. *)
  let per_code_headers : (string * string) list =
    match code with
    | Mcp_error_code.Auth_error -> [ ("www-authenticate", "Bearer") ]
    | Mcp_error_code.Not_ready -> [ ("retry-after", "2") ]
    | Mcp_error_code.Backpressure_shed -> [ ("retry-after", "1") ]
    | _ -> []
  in
  let headers =
    Httpun.Headers.of_list
      ((("content-length", string_of_int (String.length body))
       :: per_code_headers)
      @ extra_headers
      @ json_headers ~deps session_id protocol_version origin)
  in
  let response =
    Httpun.Response.create ~headers (Mcp_error_code.to_http_status code)
  in
  safe_respond_with_string reqd response body
