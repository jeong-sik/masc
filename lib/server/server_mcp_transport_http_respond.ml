(** Server_mcp_transport_http_respond — HTTP MCP error / not-ready /
    rate-limit response factories. *)

(** [safe_respond_with_string] guards [Httpun.Reqd.respond_with_string]
    against the [Failure "invalid state, currently handling error"] race
    that occurs when a client disconnects while a long AGENT_CORE turn is in
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
     (2026-05-05 AGENT_CORE cancel race), not a catch-all. *)
  Cancel_safe.observe
    ~on_exn:(function
      | Failure msg ->
          Log.Server.warn
            "[mcp-http] respond_with_string skipped (reqd invalid state; \
             2026-05-05 AGENT_CORE cancel race): %s"
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
    ~(deps : Server_mcp_transport_http_types.deps) ~request_authority request reqd
    ~session_id ~protocol_version ~(code : Mcp_error_code.t) msg =
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
    | Mcp_error_code.Auth_error ->
      [ ( "www-authenticate"
        , Server_oauth_metadata.challenge_for_authority request_authority ) ]
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

let mcp_auth_reject_reason_label
    (failure : Server_mcp_transport_http_types.auth_failure) =
  (* An absent [auth_error_code] folds to the fixed "unclassified"
     label on purpose — the metric label set must stay bounded, and
     the absence itself is what gets counted. Nothing is silently
     repaired: the paired [Log.Auth] event carries the full failure
     message and a [`Null] reason for the same reject. DET-OK. *)
  Option.value ~default:"unclassified" failure.auth_error_code

let mcp_auth_reject_details ~endpoint ~claimed_agent ~token_presented
    ~session_id (failure : Server_mcp_transport_http_types.auth_failure) =
  let opt_string = function
    | Some value -> `String value
    | None -> `Null
  in
  `Assoc
    [
      ("endpoint", `String endpoint);
      ("reason", opt_string failure.auth_error_code);
      ("message", `String failure.message);
      ("claimed_agent", opt_string claimed_agent);
      ("token_presented", `Bool token_presented);
      (* [`Null] when the request carried no [Mcp-Session-Id]
         (e.g. h2 DELETE rejected before session resolution). *)
      ("session_id", opt_string session_id);
    ]

(* Auth reject boundary observation. The transport is the only place
   that turns an [auth_failure] into a client-visible 401, so it is
   the only place that can record the rejection server-side. Before
   this the reject produced no log line, no metric, and no audit
   trace: on 2026-08-18 every external MCP credential had gone stale
   after a token rotation and the operator surface could not
   distinguish "no client ever connected" from "every client is being
   rejected" ([mcp_transport_sessions.json] empty either way).
   The raw bearer is never logged — only whether one was presented. *)
let record_mcp_auth_reject ~endpoint ~claimed_agent ~token_presented
    ~session_id (failure : Server_mcp_transport_http_types.auth_failure) =
  Log.Auth.emit Log.Warn
    ~details:
      (mcp_auth_reject_details ~endpoint ~claimed_agent ~token_presented
         ~session_id failure)
    ~category:Log.Routine
    (Printf.sprintf "MCP auth rejected: %s (%s)" endpoint failure.message);
  Transport_metrics.inc_mcp_auth_reject ~endpoint
    ~reason:(mcp_auth_reject_reason_label failure)

let respond_mcp_auth_error ~(deps : Server_mcp_transport_http_types.deps)
    ~request_authority ~endpoint request reqd ~session_id ~protocol_version
    (failure : Server_mcp_transport_http_types.auth_failure) =
  record_mcp_auth_reject ~endpoint
    ~claimed_agent:(Server_auth.agent_from_request request)
    ~token_presented:(Option.is_some (deps.auth_token_from_request request))
    ~session_id:(Some session_id) failure;
  respond_mcp_error
    ?data:
      (Option.map
         (fun code -> `Assoc [ ("auth_error_code", `String code) ])
         failure.auth_error_code)
    ~code:Mcp_error_code.Auth_error ~deps ~request_authority request reqd
    ~session_id ~protocol_version failure.message

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
    200 스트림을 열기 전에 404 + 새 [Mcp-Session-Id] 로 응답한다. 기존엔 200 송출 후
    [Writer.close] 만 해 "200 OK + 즉시 닫힌 빈 스트림"이 되어 MCP 클라이언트가 정상
    종료와 구분 못 하고 같은 stale [Mcp-Session-Id] 로 무한 재시도했다(2026-06-28
    진단). POST JSON-RPC 경로([server_mcp_transport_http.ml] 의 [Unknown_session] 분기)와
    동일 패턴 — 404 + 새 session 헤더로 클라이언트가 [initialize] 를 재수행하게 한다. *)
let respond_sse_register_error ~(deps : Server_mcp_transport_http_types.deps)
    ~origin ~protocol_version reqd msg =
  let new_session_id = Mcp_session.generate () in
  let body =
    Yojson.Safe.to_string (error_body ~code:Mcp_error_code.Invalid_request msg)
  in
  let headers =
    Httpun.Headers.of_list
      ( ("content-length", string_of_int (String.length body))
      :: json_headers ~deps new_session_id protocol_version origin )
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
