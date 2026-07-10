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
     intent — adding a backtrace there would just churn parsers.

     RFC-0106 P1: routed via [Cancel_safe.observe] so the Cancelled
     re-raise discipline lives in one place. The [Failure] arm is
     preserved inside [on_exn] because it is a typed boundary
     (2026-05-05 OAS cancel race), not a catch-all. *)
  Cancel_safe.observe
    ~on_exn:(function
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
              summary backtrace)
    (fun () -> Httpun.Reqd.respond_with_string reqd response body)

let mcp_headers = Server_mcp_transport_http_headers.mcp_headers

let json_headers = Server_mcp_transport_http_headers.json_headers

let json_headers_without_session_id =
  Server_mcp_transport_http_headers.json_headers_without_session_id

(* RFC-0098 — typed SSOT for transport-boundary error envelopes. *)

(** Pure-JSON body builder shared by [respond_mcp_error] and
    SSE batch builders. Splitting it out makes the wire shape diffable
    and testable without instantiating an [Httpun.Reqd.t]. *)
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

(* [respond_not_ready] is intentionally retained outside
   [respond_mcp_error]: it runs before [json_headers] / [session_id]
   are available. Widening [respond_mcp_error] to the pre-runtime case
   is a separate concern. *)

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

(** [respond_sse_register_error] — SSE GET register 검증(unknown/expired session) 실패 시,
    200 스트림을 열기 전에 session id 없는 404 로 응답한다. 기존엔 200 송출 후
    [Writer.close] 만 해 "200 OK + 즉시 닫힌 빈 스트림"이 되어 MCP 클라이언트가 정상
    종료와 구분 못 하고 같은 stale [Mcp-Session-Id] 로 무한 재시도했다(2026-06-28
    진단). POST JSON-RPC 경로([server_mcp_transport_http.ml] 의 [Unknown_session] 분기)와
    동일 패턴 — 클라이언트는 session 헤더 없이 [initialize] 를 재수행해야 한다. *)
let respond_sse_register_error ~(deps : Server_mcp_transport_http_types.deps)
    ~origin ~protocol_version reqd msg =
  let body =
    Yojson.Safe.to_string (error_body ~code:Mcp_error_code.Invalid_request msg)
  in
  let headers =
    Httpun.Headers.of_list
      ( ("content-length", string_of_int (String.length body))
      :: json_headers_without_session_id ~deps protocol_version origin )
  in
  safe_respond_with_string reqd (Httpun.Response.create ~headers `Not_found) body

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
