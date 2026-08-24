(** TUI HTTP client — Dashboard API wrapper over Masc_http_client. *)

let report_err prefix msg = Printf.sprintf "(%s: %s)" prefix msg
let default_timeout_sec = 10.0
let request_timeout_sec () = default_timeout_sec
let keeper_chat_timeout_sec = 180.0

(* One name for the send target. The buffered send and the streaming send are
   two ways of reading the same turn, not two endpoints, and a contract test
   pins that this literal appears once so they cannot drift apart. *)
let keeper_chat_stream_path = "/api/v1/keepers/chat/stream"
let mcp_path = "/mcp"
let observer_stream_path = "/mcp?sse_kind=observer"
let keeper_turn_interrupt_path = "/api/v1/keepers/turn/interrupt"
let keeper_tool_approval_path = "/api/v1/keepers/tool-approval"

let trim_nonempty = String_util.trim_nonempty

let first_nonempty_env names =
  List.find_map
    (fun name -> Option.bind (Env_config_core.raw_value_opt name) trim_nonempty)
    names

let sanitize_header_value value =
  value
  |> String.map (function
       | '\r' | '\n' -> ' '
       | c -> c)
  |> String.trim

let default_agent_name = Masc_tui_credential.agent_name

(* One name for the bearer the write routes require, so the header builder and
   the surfaces that report its absence cannot disagree about whether this
   process holds one.

   The bearer is discovered once, at boot, from the workspace the TUI was told
   to open -- not per request. This module is never handed a base path, and
   resolving one on its own would let the client present the credential of a
   workspace other than the one on screen. *)
let operator_token_cell = ref None

(* Carry out [Masc_tui_credential.plan]. The environment wins so a single run
   can be pointed at a different credential; otherwise the bearer comes from the
   workspace, and a workspace that demands one but holds none gets one minted.

   Minting grants nothing this process did not already have: the credential
   store is a directory under the workspace, so anything that can read the
   bearer masc login wrote can equally write another. The trust boundary is
   filesystem access to the workspace, not possession of the token. What it
   does remove is the operator's obligation to carry a secret from shell to
   shell, which is where every refusal in this file started.

   Admin because that is the role [masc login] issues for this agent, and the
   keeper lifecycle routes the TUI already offers require it -- minting a
   narrower role would leave working surfaces failing. *)
let install_operator_token ~base_path ~host ~port =
  let cfg = Auth.load_auth_config base_path in
  (* The auth directory, not the config file: a missing config reads as the
     default, so its absence proves nothing about whether a workspace is here.
     The directory holds the credential store, so a workspace a server has ever
     served has one.

     Read before anything else in startup can create it. Other startup steps do
     make directories under .masc for a base path that names nothing -- a
     mistyped flag gets an empty .masc/keepers -- and a check that ran after
     one of those had made .masc/auth would read its own footprint as evidence
     of a workspace. *)
  let workspace_initialized = Sys.file_exists (Auth.auth_dir base_path) in
  let outcome =
    match
      Masc_tui_credential.plan
        ~env_token:(first_nonempty_env [ Masc_tui_credential.token_env_var ])
        ~workspace_token:
          (Auth_login.read_persisted_token ~base_path
             ~agent_name:default_agent_name)
        ~workspace_requires_token:(cfg.enabled && cfg.require_token)
        ~workspace_initialized
    with
    | Masc_tui_credential.Use token ->
        operator_token_cell := Some token;
        Masc_tui_credential.Held
    | Masc_tui_credential.Go_without ->
        operator_token_cell := None;
        Masc_tui_credential.Not_required
    | Masc_tui_credential.No_workspace ->
        operator_token_cell := None;
        Masc_tui_credential.Unavailable Masc_tui_credential.no_workspace_detail
    | Masc_tui_credential.Mint -> (
        match
          Auth_login.mint ~base_path ~host ~port
            ~agent_name:default_agent_name ~role:Masc_domain.Admin
            ~token_env_var:Masc_tui_credential.token_env_var
            ~token_lifetime:Auth_login.Long_lived ()
        with
        | Ok report ->
            operator_token_cell := Some report.bearer_token;
            Masc_tui_credential.Minted
        | Error err ->
            operator_token_cell := None;
            Masc_tui_credential.Unavailable
              (Masc_domain.masc_error_to_string err))
  in
  outcome

let operator_token () = !operator_token_cell
let operator_token_present () = Option.is_some (operator_token ())

let auth_headers () =
  let agent_header = [ ("X-MASC-Agent", default_agent_name) ] in
  match operator_token () with
  | Some token ->
      ("Authorization", "Bearer " ^ sanitize_header_value token) :: agent_header
  | None -> agent_header

let json_headers headers =
  ("Content-Type", "application/json") :: headers

let host_for_url host =
  if String.contains host ':' && not (String.starts_with ~prefix:"[" host) then
    "[" ^ host ^ "]"
  else host

let url_of ~(host : string) ~(port : int) ~(path : string) =
  Printf.sprintf "http://%s:%d%s" (host_for_url host) port path

let percent_encode_path_segment value = Uri.pct_encode value

let request_clock () = Eio_context.get_clock_opt ()

(** Send an HTTP GET request and return the structured status/body pair. *)
let http_get ~(host : string) ~(port : int) ~(path : string) :
    (int * string, string) result =
  let url = url_of ~host ~port ~path in
  match
    Masc_http_client.get_sync ?clock:(request_clock ())
      ~timeout_sec:(request_timeout_sec ()) ~url ~headers:(auth_headers ()) ()
  with
  | Ok (status, body) -> Ok (status, body)
  | Error e -> Error (report_err "GET failed" e)

(** Send an HTTP POST request with a JSON body and return the structured status/body pair. *)
let http_post ~headers ~(host : string) ~(port : int) ~(path : string)
    ~(body : string) : (int * string, string) result =
  let url = url_of ~host ~port ~path in
  match
    Masc_http_client.post_sync ?clock:(request_clock ())
      ~timeout_sec:(request_timeout_sec ()) ~url ~headers:(json_headers headers)
      ~body ()
  with
  | Ok (status, body) -> Ok (status, body)
  | Error e -> Error (report_err "POST failed" e)

(* A refusal is about this client's credential, not about the surface that
   asked for the data. Every surface used to paste the server's auth JSON into
   the terminal -- "HTTP 401: {\"error\":\"[AuthError] Invalid token..." -- which
   names neither what is wrong nor what clears it. Answered here because this
   is the one place that knows what was presented. Other statuses keep the
   server's own words: those are about the request, and the surface is right to
   show them. *)
let decode_json ~allow_empty ~status_code ~body =
  match status_code with
  | 401 | 403 ->
      Error
        (Masc_tui_credential.refusal
           ~credential_sent:(operator_token_present ()))
  | _ ->
      Masc.Tui_decode.decode_json_response_body ~allow_empty ~status_code ~body

(** GET a JSON response from a dashboard endpoint. *)
let get_json ~(host : string) ~(port : int) ~(path : string) : (Yojson.Safe.t, string) result =
  match http_get ~host ~port ~path with
  | Error e -> Error e
  | Ok (status_code, body) -> decode_json ~allow_empty:false ~status_code ~body

(** POST a JSON body and parse the JSON response. *)
let post_json ~(host : string) ~(port : int) ~(path : string) ~(body : string) : (Yojson.Safe.t, string) result =
  match http_post ~headers:(auth_headers ()) ~host ~port ~path ~body with
  | Error e -> Error e
  | Ok (status_code, body) -> decode_json ~allow_empty:true ~status_code ~body

let post_keeper_chat ~(host : string) ~(port : int)
    (request : Masc_tui_keeper_chat_projection.request) :
    ( Masc_tui_keeper_chat_projection.response
    , Masc_tui_keeper_chat_projection.error )
    result =
  let url = url_of ~host ~port ~path:keeper_chat_stream_path in
  let headers =
    json_headers
      (("Accept", "text/event-stream") :: auth_headers ())
  in
  let body = Masc_tui_keeper_chat_projection.request_body request in
  match
    Masc_http_client.post_sync ?clock:(request_clock ())
      ~timeout_sec:keeper_chat_timeout_sec ~url ~headers ~body ()
  with
  | Error detail ->
      Error (Masc_tui_keeper_chat_projection.Transport_error detail)
  | Ok (status, response_body)
    when not (Masc.Tui_decode.is_success_http_status status) ->
      Error
        (Masc_tui_keeper_chat_projection.Http_error
           { status; body = response_body })
  | Ok (_, response_body) ->
      Masc_tui_keeper_chat_projection.decode_response_with_provenance ~request
        response_body
      |> Result.map_error (fun error ->
             Masc_tui_keeper_chat_projection.Protocol_error error)

(** Send a keeper chat turn and hand each response chunk to [on_chunk] as it
    arrives, so the caller can draw the turn while it runs.

    The turn's outcome still comes from the strict decode over the complete
    body, which the streaming read returns as well. So this returns exactly
    what {!post_keeper_chat} would have returned for the same stream, and a
    defect in whatever [on_chunk] drives cannot change it.

    [keeper_chat_timeout_sec] is the silence bound here rather than a total
    cap. That is strictly more room than the buffered send had: a turn that
    keeps emitting is no longer cut off at all, and one that goes quiet is
    still bounded by the same number. *)
let post_keeper_chat_streaming ~clock ~(host : string) ~(port : int)
    ~(on_chunk : string -> unit)
    (request : Masc_tui_keeper_chat_projection.request) :
    ( Masc_tui_keeper_chat_projection.response
    , Masc_tui_keeper_chat_projection.error )
    result =
  let url = url_of ~host ~port ~path:keeper_chat_stream_path in
  let headers =
    json_headers (("Accept", "text/event-stream") :: auth_headers ())
  in
  let body = Masc_tui_keeper_chat_projection.request_body request in
  match
    Masc_http_client.post_stream ~clock
      ~idle_timeout_sec:keeper_chat_timeout_sec ~url ~headers ~body ~on_chunk ()
  with
  | Error detail ->
      Error (Masc_tui_keeper_chat_projection.Transport_error detail)
  | Ok (Masc_http_client.Pool.Buffered { status; body; _ }) ->
      Error (Masc_tui_keeper_chat_projection.Http_error { status; body })
  | Ok (Masc_http_client.Pool.Streamed { response; _ }) ->
      Masc_tui_keeper_chat_projection.decode_response_with_provenance ~request
        response.Masc_http_client.Pool.body
      |> Result.map_error (fun error ->
             Masc_tui_keeper_chat_projection.Protocol_error error)

(** Fetch a keeper's durable tool-call log
    ([GET /api/v1/keepers/:name/tool-calls]). *)
let fetch_keeper_calls ~(host : string) ~(port : int) ~(keeper_name : string)
    ~(limit : int) : (Masc.Tui_decode.keeper_calls_snapshot, string) result =
  let path =
    Printf.sprintf "/api/v1/keepers/%s/tool-calls?limit=%d"
      (percent_encode_path_segment keeper_name)
      (max 1 limit)
  in
  match http_get ~host ~port ~path with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status)
    ->
      Error (Printf.sprintf "tool calls returned %d: %s" status body)
  | Ok (_, body) -> (
      match Yojson.Safe.from_string body with
      | json ->
          Masc.Tui_decode.decode_keeper_calls_snapshot
            ~requested_keeper:keeper_name json
      | exception Yojson.Json_error detail ->
          Error ("tool calls were not JSON: " ^ detail))

(** Open the MCP session the observer feed is registered under.

    The transport registers an SSE observer only for a session it has seen
    [initialize]; the id of the new session comes back in the
    [Mcp-Session-Id] response header. *)
let open_mcp_session ~(host : string) ~(port : int) ~(client_version : string)
    : (string, string) result =
  let url = url_of ~host ~port ~path:mcp_path in
  let headers =
    json_headers
      (("Accept", "application/json, text/event-stream") :: auth_headers ())
  in
  let body = Masc_tui_observer.initialize_request_body ~client_version in
  match
    Masc_http_client.post_response_sync ?clock:(request_clock ())
      ~timeout_sec:(request_timeout_sec ()) ~url ~headers ~body ()
  with
  | Error detail -> Error (report_err "MCP initialize failed" detail)
  | Ok { Masc_http_client.status; body; _ }
    when not (Masc.Tui_decode.is_success_http_status status) ->
      Error (Printf.sprintf "MCP initialize returned %d: %s" status body)
  | Ok { Masc_http_client.headers; _ } ->
      Masc_tui_observer.session_id_of_headers headers

(** Read the runtime's event feed until it ends.

    Blocks on the calling fiber for the life of the stream and hands every
    body chunk to [on_chunk] as it arrives. The silence bound is the one
    the keeper chat stream uses: a feed from a runtime with keepers turning
    that says nothing for that long has gone quiet, and the caller reopens
    it on its own schedule. [Ok ()] is the server closing the stream; a
    refusal and a transport failure both come back as [Error]. *)
let observe_runtime_events ~clock ~(host : string) ~(port : int)
    ~(session_id : string) ~(on_chunk : string -> unit) : (unit, string) result
    =
  let url = url_of ~host ~port ~path:observer_stream_path in
  let headers =
    ("Accept", "text/event-stream")
    :: ("Mcp-Session-Id", sanitize_header_value session_id)
    :: auth_headers ()
  in
  match
    Masc_http_client.get_stream ~clock ~idle_timeout_sec:keeper_chat_timeout_sec
      ~url ~headers ~on_chunk ()
  with
  | Error detail -> Error (report_err "observer stream failed" detail)
  | Ok (Masc_http_client.Pool.Buffered { status; body; _ }) ->
      Error (Printf.sprintf "observer stream refused with %d: %s" status body)
  | Ok (Masc_http_client.Pool.Streamed _) -> Ok ()

(** One MCP [tools/call] under an existing session.

    The task tools ([masc_add_task], [masc_transition]) have no REST route;
    this is how the dashboard calls them and now how the TUI does. The
    session is the one the observer feed opened, or one the caller opened
    for this call; the server keeps sessions across requests. *)
let call_mcp_tool ~(host : string) ~(port : int) ~(session_id : string)
    ~(request_id : string) ~(tool : string)
    ~(arguments : (string * Yojson.Safe.t) list) :
    (Masc_tui_mcp.outcome, string) result =
  let headers =
    json_headers
      (("Accept", "application/json, text/event-stream")
      :: ("Mcp-Session-Id", sanitize_header_value session_id)
      :: auth_headers ())
  in
  let body = Masc_tui_mcp.request_body ~request_id ~tool ~arguments in
  match http_post ~headers ~host ~port ~path:mcp_path ~body with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status)
    ->
      Error (Printf.sprintf "tools/call returned %d: %s" status body)
  | Ok (_, body) -> Masc_tui_mcp.outcome_of_body ~request_id body

(** Fetch a keeper's durable chat transcript.

    The pane's scrollback used to be session-local while the server kept the
    transcript all along. *)
let fetch_keeper_chat_history ~(host : string) ~(port : int)
    ~(keeper_name : string) :
    (Masc_tui_keeper_chat_history.decoded, string) result =
  let path =
    Printf.sprintf "/api/v1/keepers/%s/chat/history"
      (percent_encode_path_segment keeper_name)
  in
  match http_get ~host ~port ~path with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status) ->
      Error (Printf.sprintf "chat history returned %d: %s" status body)
  | Ok (_, body) -> (
      match Yojson.Safe.from_string body with
      | json -> Masc_tui_keeper_chat_history.rows_of_json json
      | exception Yojson.Json_error detail ->
          Error ("chat history was not JSON: " ^ detail))

(** Fetch one page of chat rows older than [before].

    [before] absent asks for the newest window, which is what the transcript
    fetch already returns; the pane passes a cursor, so it is required here. *)
let fetch_keeper_chat_history_page ~(host : string) ~(port : int)
    ~(keeper_name : string) ~(before : float) :
    (Masc_tui_keeper_chat_history.page, string) result =
  let path =
    (* %.17g rather than %h: both round-trip through float_of_string, but the
       hex form carries a '+' in its exponent, which a query string reads as a
       space. 17 significant digits is the shortest width that is exact for
       every double. *)
    Printf.sprintf "/api/v1/keepers/%s/chat/history/page?before=%.17g"
      (percent_encode_path_segment keeper_name)
      before
  in
  match http_get ~host ~port ~path with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status) ->
      Error (Printf.sprintf "chat history page returned %d: %s" status body)
  | Ok (_, body) -> (
      match Yojson.Safe.from_string body with
      | json -> Masc_tui_keeper_chat_history.page_of_json json
      | exception Yojson.Json_error detail ->
          Error ("chat history page was not JSON: " ^ detail))

(** What the server did with a request to interrupt a keeper's current turn.

    [Signalled] reports that the signal reached the turn switch, and nothing
    more. Whether the fiber then stops is a later event: a turn parked in an
    uncancellable section keeps running, and reading this as the outcome is
    what hid a 63-minute hang (masc #29229). *)
type interrupt_signal =
  | Signalled of { turn_id : int option }
  | Not_signalled of
      { reason : string
      ; detail : string option
      }

let decode_interrupt_signal json =
  let field name =
    match json with
    | `Assoc fields -> List.assoc_opt name fields
    | _ -> None
  in
  let string_of name =
    match field name with
    | Some (`String value) -> Some value
    | Some _ | None -> None
  in
  let turn_id =
    match field "turn_id" with
    | Some (`Int value) -> Some value
    | Some _ | None -> None
  in
  match field "signalled" with
  | Some (`Bool true) -> Ok (Signalled { turn_id })
  | Some (`Bool false) ->
      Ok
        (Not_signalled
           { reason = Option.value ~default:"unstated" (string_of "reason")
           ; detail = string_of "detail"
           })
  | Some _ | None -> Error "interrupt response has no signalled flag"

(** Answer a tool call the keeper is holding.

    [settled] reports whether a wait was actually released. False means the
    call had already timed out or been answered, so the pane says that rather
    than showing the answer as taken. *)
let post_keeper_tool_approval ~(host : string) ~(port : int)
    ~(keeper_name : string) ~(tool_call_id : string) ~(allow : bool) :
    (bool, string) result =
  let body =
    Yojson.Safe.to_string
      (`Assoc
         [ ("name", `String keeper_name)
         ; ("tool_call_id", `String tool_call_id)
         ; ("decision", `String (if allow then "approve" else "deny"))
         ])
  in
  match post_json ~host ~port ~path:keeper_tool_approval_path ~body with
  | Error detail -> Error detail
  | Ok json -> (
      match json with
      | `Assoc fields -> (
          match List.assoc_opt "settled" fields with
          | Some (`Bool settled) -> Ok settled
          | Some _ | None -> Error "approval response has no settled flag")
      | _ -> Error "approval response was not a JSON object")

let post_keeper_turn_interrupt ~(host : string) ~(port : int)
    ~(keeper_name : string) : (interrupt_signal, string) result =
  let body =
    Yojson.Safe.to_string (`Assoc [ ("name", `String keeper_name) ])
  in
  match
    post_json ~host ~port ~path:keeper_turn_interrupt_path ~body
  with
  | Error detail -> Error detail
  | Ok json -> decode_interrupt_signal json

let fetch_keeper_chat_operation ~(host : string) ~(port : int)
    (request : Masc_tui_keeper_chat_projection.request) :
    ( Masc_tui_keeper_chat_projection.operation_reconciliation
    , Masc_tui_keeper_chat_projection.error )
    result =
  let path =
    Printf.sprintf "/api/v1/keepers/%s/chat/operations/%s"
      (percent_encode_path_segment request.keeper_name)
      (percent_encode_path_segment request.request_id)
  in
  match http_get ~host ~port ~path with
  | Error detail ->
      Error (Masc_tui_keeper_chat_projection.Transport_error detail)
  | Ok (status, response_body)
    when not (Masc.Tui_decode.is_success_http_status status) ->
      Error
        (Masc_tui_keeper_chat_projection.Http_error
           { status; body = response_body })
  | Ok (_, response_body) ->
      (match Yojson.Safe.from_string response_body with
       | json ->
           Masc_tui_keeper_chat_projection.decode_operation_reconciliation
             ~request json
           |> Result.map_error (fun error ->
                  Masc_tui_keeper_chat_projection.protocol_error error)
       | exception Yojson.Json_error detail ->
           Error
             (Masc_tui_keeper_chat_projection.protocol_error
                (Masc_tui_keeper_chat_projection.Malformed_event
                   ("Keeper chat operation response is invalid JSON: "
                  ^ detail))))

(** Fetch the live keeper roster from [GET /api/v1/gate/keepers].

    The Keepers surface needs one fact the durable metadata on disk cannot
    give it: whether a keepalive fiber is running each keeper. This route is
    [masc_keeper_list], the same reading the channel connectors use, and it
    answers in a few kilobytes — the operator snapshot carries the same fact
    inside a payload 150 times larger.

    The status is returned rather than folded into an error string: this route
    requires an operator token, and "no token" is a different thing for the
    surface to say than "the read failed". *)
let fetch_keeper_runtimes ~(host : string) ~(port : int) :
    (int * string, string) result =
  http_get ~host ~port ~path:"/api/v1/gate/keepers?detailed=true"

(** POST a keeper lifecycle action ([boot] / [shutdown]).

    Returns the HTTP status alongside the body: a paused owner refuses [boot]
    with 409, and the caller routes that into the resume-then-boot recovery
    rather than reporting it as a failure. Collapsing the status into an error
    string would make that decision a substring match. *)
let post_keeper_lifecycle ~(host : string) ~(port : int) ~(keeper_name : string)
    ~(action : string) : (int * string, string) result =
  let path =
    Printf.sprintf "/api/v1/keepers/%s/%s"
      (percent_encode_path_segment keeper_name)
      (percent_encode_path_segment action)
  in
  http_post ~headers:(auth_headers ()) ~host ~port ~path
    ~body:Masc_tui_keeper_control.lifecycle_body

(** POST a keeper directive ([pause] / [resume] / [wakeup]). *)
let post_keeper_directive ~(host : string) ~(port : int)
    ~(keeper_name : string) ~(action : string)
    ~(operator_operation_id : string) : (int * string, string) result =
  let path =
    Printf.sprintf "/api/v1/keepers/%s/directive"
      (percent_encode_path_segment keeper_name)
  in
  let body =
    Masc_tui_keeper_control.directive_body ~operator_operation_id action
  in
  http_post ~headers:(auth_headers ()) ~host ~port ~path ~body

(** Fetch /api/v1/dashboard/briefing (Mission / Overview snapshot). *)
let fetch_dashboard_briefing ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/dashboard/briefing"

(** Fetch /api/v1/dashboard/transport-health (delivery-path summary). *)
let fetch_transport_health ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/dashboard/transport-health"

(** Fetch the actor-scoped operator summary that owns pending confirmations. *)
let fetch_operator_snapshot ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port
    ~path:"/api/v1/operator?view=summary&include_messages=0&include_keepers=0"

(** POST /api/v1/operator/confirm to approve/deny a pending confirmation. *)
let operator_confirm_body ~(token : string)
    ~(decision : Masc_tui_operator_projection.approval_decision) =
  let decision = Masc_tui_operator_projection.approval_decision_wire decision in
  Yojson.Safe.to_string
    (`Assoc [ ("confirm_token", `String token); ("decision", `String decision) ])

let post_operator_confirm ~(host : string) ~(port : int) ~(token : string)
    ~(decision : Masc_tui_operator_projection.approval_decision) :
    (Masc_tui_operator_projection.confirm_outcome, string) result =
  let body = operator_confirm_body ~token ~decision in
  match post_json ~host ~port ~path:"/api/v1/operator/confirm" ~body with
  | Error _ as error -> error
  | Ok json ->
      Masc_tui_operator_projection.decode_confirm_response
        ~expected_token:token ~expected_decision:decision json

(** Fetch /api/v1/board (post list). *)
let fetch_board ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/board"

(** POST /api/v1/tools/masc_board_post. The draft follows the commit-message
    shape -- first line is the title, the rest is the body -- and the server
    stamps the author from the agent header, so the payload carries text
    only. The response is the tools envelope [{ok, message}]; interpreting it
    stays with the caller. *)
let post_board_new ~(host : string) ~(port : int) ~(title : string)
    ~(body : string) : (Yojson.Safe.t, string) result =
  let payload =
    `Assoc [ ("title", `String title); ("body", `String body) ]
  in
  post_json ~host ~port ~path:"/api/v1/tools/masc_board_post"
    ~body:(Yojson.Safe.to_string payload)

(** POST /api/v1/tools/masc_goal_transition. The action travels as the tool's
    own wire word via [Goal_phase.Public_action.to_string] rather than a
    local literal, so the TUI and the tool cannot disagree about what
    "drop" means. The server owns the phase rules; an invalid transition is
    its rejection to return, not the TUI's to pre-guess. *)
let post_goal_transition ~(host : string) ~(port : int) ~(goal_id : string)
    ~(action : Goal_phase.Public_action.t)
    ~(note : string option) : (Yojson.Safe.t, string) result =
  let payload =
    `Assoc
      ([ ("goal_id", `String goal_id)
       ; ("action", `String (Goal_phase.Public_action.to_string action))
       ]
      @
      match note with
      | Some text -> [ ("note", `String text) ]
      | None -> [])
  in
  post_json ~host ~port ~path:"/api/v1/tools/masc_goal_transition"
    ~body:(Yojson.Safe.to_string payload)

(** POST /api/v1/tools/masc_board_vote. [up] rides as a bool rather than a
    string so no direction word exists here to drift from the tool's. *)
let post_board_vote ~(host : string) ~(port : int) ~(post_id : string)
    ~(up : bool) : (Yojson.Safe.t, string) result =
  let payload =
    `Assoc
      [ ("post_id", `String post_id)
      ; ("direction", `String (if up then "up" else "down"))
      ]
  in
  post_json ~host ~port ~path:"/api/v1/tools/masc_board_vote"
    ~body:(Yojson.Safe.to_string payload)

(** POST /api/v1/tools/masc_board_comment. The author is stamped by the
    route from the agent header, exactly as for a new post. *)
let post_board_comment ~(host : string) ~(port : int) ~(post_id : string)
    ~(content : string) : (Yojson.Safe.t, string) result =
  let payload =
    `Assoc [ ("post_id", `String post_id); ("content", `String content) ]
  in
  post_json ~host ~port ~path:"/api/v1/tools/masc_board_comment"
    ~body:(Yojson.Safe.to_string payload)

(** Fetch /api/v1/board/<postId> (post detail + comments). *)
let fetch_board_post ~(host : string) ~(port : int) ~(post_id : string) : (Yojson.Safe.t, string) result =
  get_json ~host ~port
    ~path:
      (Printf.sprintf "/api/v1/board/%s?format=flat"
         (percent_encode_path_segment post_id))

(** Fetch /api/v1/dashboard/scheduled-automation (schedule list projection).
    The server sorts active-first by due time and caps rows at its own limit,
    so the path alone is the whole request. *)
let fetch_schedules ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/dashboard/scheduled-automation"

(** POST /api/v1/tools/masc_schedule_cancel. The payload is the tool's own
    argument contract, so validation is the tool's, not duplicated here.
    [cancelled_by_kind] is omitted: the tool defaults it to human operator,
    which is what a terminal operator is. The reason is a fixed audit phrase --
    the arm display already named which schedule the second press cancels. *)
let post_schedule_cancel ~(host : string) ~(port : int) ~(schedule_id : string)
    : (Yojson.Safe.t, string) result =
  let payload =
    `Assoc
      [ ("schedule_id", `String schedule_id)
      ; ("cancelled_by_id", `String default_agent_name)
      ; ("reason", `String "cancelled from the TUI")
      ]
  in
  post_json ~host ~port ~path:"/api/v1/tools/masc_schedule_cancel"
    ~body:(Yojson.Safe.to_string payload)

(** Fetch /api/v1/dashboard/logs. The server caps [limit] at 3000; the TUI asks
    for a screenful's worth of history rather than the whole ring. *)
let fetch_dashboard_logs ~(host : string) ~(port : int) ~(limit : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port
    ~path:(Printf.sprintf "/api/v1/dashboard/logs?limit=%d" (max 1 (min 3000 limit)))

(** Fetch /api/v1/dashboard/tools. *)
let fetch_dashboard_tools ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/dashboard/tools"

(** Fetch /api/v1/gate/connectors. *)
let fetch_connectors ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/gate/connectors"

(** Fetch /api/v1/repositories. *)
let fetch_repositories ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/repositories"

(** Fetch /api/v1/dashboard/harness-health. No window is passed: the surface
    shows what the harness decided recently, and a window is a question an
    operator asks in the dashboard rather than a default. *)
let fetch_harness_health ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/dashboard/harness-health"

(** Fetch /api/v1/verification/requests. [limit] bounds the page; the surface
    lists what is waiting rather than the whole history. *)
let fetch_verification_requests ~(host : string) ~(port : int) ~(limit : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port
    ~path:(Printf.sprintf "/api/v1/verification/requests?limit=%d" (max 1 limit))

(** Fetch /api/v1/dashboard/planning (goals + rollup + task backlog). *)
let fetch_dashboard_planning ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/dashboard/planning"

(** Fetch the operator fleet reading from /health?full=1.

    The operator snapshot does not carry it: [keeper_fleet_safety] is assembled
    in lib/server from a scan the operator projection has no path to, and the
    dependency runs server -> operator, not back. So this reads the health
    surface the dashboard already reads for the same facts.

    [full=1] is the only shape that carries the section. It is a wider payload
    than the fleet reading alone, which is why the caller polls it on the fleet
    view rather than on every tick. *)
let fetch_fleet_safety ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/health?full=1"
