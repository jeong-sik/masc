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

(* RFC-0098 — typed SSOT for transport-boundary error envelopes.
   New code should call [respond_mcp_error] with the typed
   [Mcp_error_code.t] variant; the per-code factories below remain
   as [@@deprecated] thin delegations during the migration window. *)

(** Pure-JSON body builder shared by [respond_mcp_error] and
    [mcp_internal_error_json]. Splitting it out makes the wire-shape
    diffable and testable without instantiating an [Httpun.Reqd.t]. *)
let error_body ?(id = `Null) ?data ~(code : Mcp_error_code.t) msg :
    Yojson.Safe.t =
  let error_fields =
    let base =
      [
        ("code", `Int (Mcp_error_code.to_wire_code code));
        ("message", `String msg);
      ]
    in
    match data with Some d -> base @ [ ("data", d) ] | None -> base
  in
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", id);
      ("error", `Assoc error_fields);
    ]

let respond_mcp_error ?(extra_headers = []) ?data ?id
    ~(deps : Server_mcp_transport_http_types.deps) request reqd ~session_id
    ~protocol_version ~(code : Mcp_error_code.t) msg =
  let origin = deps.get_origin request in
  let id_for_body = Option.value ~default:`Null id in
  let body =
    Yojson.Safe.to_string (error_body ~id:id_for_body ?data ~code msg)
  in
  (* Constructors qualified explicitly (Mcp_error_code.Auth_error rather
     than bare Auth_error) — consistent with #15759 P1 review on the
     legacy path; defence-in-depth against future loss of the
     [~(code : Mcp_error_code.t)] type annotation or relocation. *)
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

(* RFC-0098 PR-4 — legacy [respond_mcp_auth_error] /
   [respond_mcp_internal_error] / [mcp_internal_error_json] removed.
   PR-3 (#15793) migrated all 10 in-tree callers to [respond_mcp_error
   ~code:...] / [error_body ~code:...]. The wrappers carried no
   semantics beyond delegation and are gone. [respond_not_ready] is
   intentionally retained — it runs before [json_headers] /
   [session_id] are available; widening [respond_mcp_error] to the
   pre-runtime case is a separate concern. *)

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

(* RFC-0098 PR-4: [mcp_internal_error_json] removed.
   Call [error_body ~code:Mcp_error_code.Internal_error ...] directly. *)
