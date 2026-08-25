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
let fusion_runs_path = "/api/v1/dashboard/fusion-runs"
let runtime_probe_path = "/api/v1/dashboard/runtime-probe"

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
            ~token_lifetime:
              (Auth_login.Expires_in_hours
                 Masc_tui_credential.self_mint_expiry_hours)
            ()
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

(* A query value keeps the characters a path segment may not, and loses the
   two that end a value. A file path carries slashes, so encoding it as a path
   segment would spell them out and the server would not find the file. *)
let percent_encode_query_value value =
  Uri.pct_encode ~component:`Query_value value

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

(** Fetch the files a keeper wrote
    ([GET /api/v1/keepers/:name/file-changes]).

    The window is time rather than a row count. A count could not say what it
    had covered -- the server scans a multiple of it in fleet rows, so a
    keeper that made no more calls and a scan that stopped short arrive
    looking the same. The server bounds the window at what the read costs and
    states in its answer the window it actually covered. *)
(** One directory level of the workspace ([/api/v1/workspace/children];
    an empty [path] asks [/workspace/tree] for the root). *)
let fetch_workspace_entries ~(host : string) ~(port : int) ~(path : string) :
    (Masc.Tui_decode.workspace_tree_node list, string) result =
  let route =
    if String.equal path "" then "/api/v1/workspace/tree?depth=0&limit=200"
    else
      Printf.sprintf "/api/v1/workspace/children?path=%s&limit=500"
        (percent_encode_query_value path)
  in
  match http_get ~host ~port ~path:route with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status)
    ->
      Error (Printf.sprintf "workspace entries returned %d: %s" status body)
  | Ok (_, body) -> (
      match Yojson.Safe.from_string body with
      | exception Yojson.Json_error detail ->
          Error ("workspace entries were not JSON: " ^ detail)
      | json -> Masc.Tui_decode.decode_workspace_tree json)

(** The whole file at [path] ([/api/v1/workspace/file]). *)
let fetch_workspace_file ~(host : string) ~(port : int) ~(path : string) :
    (string, string) result =
  let route =
    Printf.sprintf "/api/v1/workspace/file?path=%s"
      (percent_encode_query_value path)
  in
  match http_get ~host ~port ~path:route with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status)
    ->
      Error (Printf.sprintf "workspace file returned %d: %s" status body)
  | Ok (_, body) -> (
      match Yojson.Safe.from_string body with
      | exception Yojson.Json_error detail ->
          Error ("workspace file was not JSON: " ^ detail)
      | json -> Masc.Tui_decode.decode_workspace_file json)

(** The file's commit history ([/api/v1/git/log]), most recent first. *)
let fetch_git_log ~(host : string) ~(port : int) ~(path : string)
    ~(limit : int) : (Masc.Tui_decode.git_log_row list, string) result =
  let route =
    Printf.sprintf "/api/v1/git/log?path=%s&limit=%d"
      (percent_encode_query_value path)
      limit
  in
  match http_get ~host ~port ~path:route with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status)
    ->
      Error (Printf.sprintf "git log returned %d: %s" status body)
  | Ok (_, body) -> (
      match Yojson.Safe.from_string body with
      | exception Yojson.Json_error detail ->
          Error ("git log was not JSON: " ^ detail)
      | json -> Masc.Tui_decode.decode_git_log json)

let fetch_keeper_file_changes ~(host : string) ~(port : int)
    ~(keeper_name : string) ~(window_hours : float) :
    (Masc.Tui_decode.file_change_snapshot, string) result =
  let path =
    Printf.sprintf "/api/v1/keepers/%s/file-changes?window_hours=%g"
      (percent_encode_path_segment keeper_name)
      (Float.max 0.0 window_hours)
  in
  match http_get ~host ~port ~path with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status)
    ->
      Error (Printf.sprintf "file changes returned %d: %s" status body)
  | Ok (_, body) -> (
      match Yojson.Safe.from_string body with
      | json -> Masc.Tui_decode.decode_file_change_snapshot json
      | exception Yojson.Json_error detail ->
          Error ("file changes were not JSON: " ^ detail))

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

let fetch_keeper_memory_journal ~(host : string) ~(port : int)
    ~(keeper_name : string) :
    (Masc_tui_keeper_chat_history.decoded, string) result =
  let path =
    Printf.sprintf "/api/v1/keepers/%s/memory-journal?limit=20"
      (percent_encode_path_segment keeper_name)
  in
  match http_get ~host ~port ~path with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status) ->
      Error (Printf.sprintf "memory journal returned %d: %s" status body)
  | Ok (_, body) ->
      (match Yojson.Safe.from_string body with
       | json -> Masc_tui_keeper_chat_history.memory_rows_of_json json
       | exception Yojson.Json_error detail ->
           Error ("memory journal was not JSON: " ^ detail))

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

(** GET /api/v1/runtime/resolved — runtimes and keeper assignments. *)
let fetch_runtime_resolved ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/runtime/resolved"

(** GET /api/v1/dashboard/runtime-probe — cached provider metadata
    reachability. [force] schedules a background refresh past the route's
    recent-value window; the returned [refresh_state] remains authoritative. *)
let fetch_runtime_probe ~(host : string) ~(port : int) ~(force : bool) :
    (Yojson.Safe.t, string) result =
  let path = if force then runtime_probe_path ^ "?force=1" else runtime_probe_path in
  get_json ~host ~port ~path

(** POST /api/v1/runtime/config/assignment — point a keeper at a runtime.
    [runtime_id = None] clears the explicit assignment back to the default. *)
let post_runtime_assignment ~(host : string) ~(port : int)
    ~(keeper_name : string) ~(runtime_id : string option) :
    (unit, string) result =
  let body =
    Yojson.Safe.to_string
      (`Assoc
         (("keeper_name", `String keeper_name)
          ::
          (match runtime_id with
           | Some id -> [ ("runtime_id", `String id) ]
           | None -> [])))
  in
  match
    post_json ~host ~port ~path:"/api/v1/runtime/config/assignment" ~body
  with
  | Error detail -> Error detail
  | Ok _ -> Ok ()

(** GET /api/v1/keepers/tool-approvals — the tool calls keepers are holding. *)
let fetch_keeper_tool_approvals ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/keepers/tool-approvals"

(** GET /api/v1/keepers/tool-approval-mode — per-keeper gate stances. *)
let fetch_keeper_tool_approval_modes ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/keepers/tool-approval-mode"

(** POST /api/v1/keepers/tool-approval-mode — set one keeper's gate stance. *)
let post_keeper_tool_approval_mode ~(host : string) ~(port : int)
    ~(keeper_name : string) ~(mode : string) : (unit, string) result =
  let body =
    Yojson.Safe.to_string
      (`Assoc [ ("name", `String keeper_name); ("mode", `String mode) ])
  in
  match
    post_json ~host ~port ~path:"/api/v1/keepers/tool-approval-mode" ~body
  with
  | Error detail -> Error detail
  | Ok _ -> Ok ()

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

(** POST /api/v1/verification/verdict — the operator's verdict on a task
    awaiting verification. The route demands a reason with a reject and takes
    none with an approve, so the variant carries it only where it rides. The
    route wants a token-bound admin credential — the one this process mints
    at startup. *)
let post_verification_verdict ~(host : string) ~(port : int)
    ~(task_id : string) ~(verdict : [ `Approve | `Reject of string ]) :
    (Yojson.Safe.t, string) result =
  let fields =
    match verdict with
    | `Approve ->
        [ ("task_id", `String task_id); ("verdict", `String "approve") ]
    | `Reject reason ->
        [ ("task_id", `String task_id)
        ; ("verdict", `String "reject")
        ; ("reason", `String reason)
        ]
  in
  post_json ~host ~port ~path:"/api/v1/verification/verdict"
    ~body:(Yojson.Safe.to_string (`Assoc fields))

(** POST /api/v1/keepers/:name/config — a partial settings patch. The body is
    exactly the fields the operator left in $EDITOR; a field absent from the
    body is absent from the patch, so the editor round-trip cannot blank a
    setting it never showed. Validation is the route's (it re-uses
    masc_keeper_up's arg parsing), not duplicated here. *)
let post_keeper_config ~(host : string) ~(port : int) ~(keeper_name : string)
    ~(patch_json : string) : (Yojson.Safe.t, string) result =
  post_json ~host ~port
    ~path:
      (Printf.sprintf "/api/v1/keepers/%s/config"
         (percent_encode_path_segment keeper_name))
    ~body:patch_json

(** POST /api/v1/keepers/:name/up — masc_keeper_up's own create-or-update
    contract. The keeper name in the path is the row the operator launched
    from; the body carries the rest of the declaration. *)
let post_keeper_up ~(host : string) ~(port : int) ~(keeper_name : string)
    ~(declaration_json : string) : (Yojson.Safe.t, string) result =
  post_json ~host ~port
    ~path:
      (Printf.sprintf "/api/v1/keepers/%s/up"
         (percent_encode_path_segment keeper_name))
    ~body:declaration_json

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

(** Fetch the current composite lane snapshot for every registered Keeper. *)
let fetch_keeper_lanes ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/keepers/composite"

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

(** Fetch the retained Fusion run registry list. *)
let fetch_fusion_runs ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:fusion_runs_path

(** Fetch one run joined to its exact typed-origin Board evidence. *)
let fetch_fusion_detail ~(host : string) ~(port : int) ~(run_id : string) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port
    ~path:(fusion_runs_path ^ "/" ^ percent_encode_path_segment run_id)

(** Fetch /api/v1/verification/requests. [limit] bounds the page; the surface
    lists what is waiting rather than the whole history. *)
let fetch_verification_requests ~(host : string) ~(port : int) ~(limit : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port
    ~path:(Printf.sprintf "/api/v1/verification/requests?limit=%d" (max 1 limit))

(** Fetch /api/v1/dashboard/planning (goals + rollup + task backlog). *)
let fetch_dashboard_planning ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/dashboard/planning"

(** Fetch /health for the server's own identity: version, the commit its
    binary was built from, and the paths it resolved. The probe shape carries
    all three, so this does not pay for [full=1]. *)
let fetch_server_identity ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/health"

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

(** GET /api/v1/keepers/:name/config — name, instructions, effective_config,
    sources. Read here for the detail pane's Instructions tab. *)
let fetch_keeper_config_snapshot ~(host : string) ~(port : int)
    ~(keeper_name : string) : (Yojson.Safe.t, string) result =
  get_json ~host ~port
    ~path:
      (Printf.sprintf "/api/v1/keepers/%s/config"
         (percent_encode_path_segment keeper_name))

(** GET /api/v1/keepers/:name/github-identity — the keeper's GitHub CLI
    identity observation (config dir, projected token env, stored and
    effective auth). *)
let fetch_keeper_github_identity ~(host : string) ~(port : int)
    ~(keeper_name : string) : (Yojson.Safe.t, string) result =
  get_json ~host ~port
    ~path:
      (Printf.sprintf "/api/v1/keepers/%s/github-identity"
         (percent_encode_path_segment keeper_name))

(** GET /api/v1/runtime/config/raw — runtime.toml's path and text as the
    server reads them. *)
let fetch_runtime_config_raw ~(host : string) ~(port : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/runtime/config/raw"

(** POST /api/v1/runtime/config/raw/preview — validate edited text without
    writing it. The body names the one field the route reads. *)
let post_runtime_config_preview ~(host : string) ~(port : int)
    ~(source_text : string) : (Yojson.Safe.t, string) result =
  post_json ~host ~port ~path:"/api/v1/runtime/config/raw/preview"
    ~body:(Yojson.Safe.to_string (`Assoc [ ("source_text", `String source_text) ]))

(** POST /api/v1/runtime/config/raw — write the edited text. Callers go
    through the preview first; this route also validates, so a race still
    fails closed. *)
let post_runtime_config_raw ~(host : string) ~(port : int)
    ~(source_text : string) : (Yojson.Safe.t, string) result =
  post_json ~host ~port ~path:"/api/v1/runtime/config/raw"
    ~body:(Yojson.Safe.to_string (`Assoc [ ("source_text", `String source_text) ]))

(** GET /api/v1/prompts — every prompt the registry serves, with the file
    value, any override, and what is currently effective. *)
let fetch_prompts ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/prompts"

(** POST /api/v1/prompts — body {key, action, value}. [action] is ["set"] or
    ["clear"]; the server persists the override and answers what it did. *)
let post_prompt_override ~(host : string) ~(port : int) ~(key : string)
    ~(value : string) : (Yojson.Safe.t, string) result =
  post_json ~host ~port ~path:"/api/v1/prompts"
    ~body:
      (Yojson.Safe.to_string
         (`Assoc
            [ ("key", `String key)
            ; ("action", `String "set")
            ; ("value", `String value)
            ]))

let post_prompt_clear ~(host : string) ~(port : int) ~(key : string)
    : (Yojson.Safe.t, string) result =
  post_json ~host ~port ~path:"/api/v1/prompts"
    ~body:
      (Yojson.Safe.to_string
         (`Assoc [ ("key", `String key); ("action", `String "clear") ]))

(** POST /api/v1/gate/connector/bind?name= — body {channel_id, keeper_name}. *)
let post_connector_bind ~(host : string) ~(port : int) ~(connector : string)
    ~(body_json : string) : (Yojson.Safe.t, string) result =
  post_json ~host ~port
    ~path:
      (Printf.sprintf "/api/v1/gate/connector/bind?name=%s"
         (percent_encode_path_segment connector))
    ~body:body_json

(** POST /api/v1/gate/connector/unbind?name= — body {channel_id}. *)
let post_connector_unbind ~(host : string) ~(port : int) ~(connector : string)
    ~(body_json : string) : (Yojson.Safe.t, string) result =
  post_json ~host ~port
    ~path:
      (Printf.sprintf "/api/v1/gate/connector/unbind?name=%s"
         (percent_encode_path_segment connector))
    ~body:body_json

(** One [resources/list] over the MCP endpoint, on an open session. *)
let call_mcp_resources_list ~(host : string) ~(port : int)
    ~(session_id : string) ~(request_id : string) :
    ((string * string) list, string) result =
  let headers =
    json_headers
      (("Accept", "application/json, text/event-stream")
      :: ("Mcp-Session-Id", sanitize_header_value session_id)
      :: auth_headers ())
  in
  let body = Masc_tui_mcp.resources_list_request_body ~request_id in
  match http_post ~headers ~host ~port ~path:mcp_path ~body with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status)
    ->
      Error (Printf.sprintf "resources/list returned %d: %s" status body)
  | Ok (_, body) -> Masc_tui_mcp.resources_of_body ~request_id body

(** One [resources/read] over the MCP endpoint, on an open session. *)
let call_mcp_resources_read ~(host : string) ~(port : int)
    ~(session_id : string) ~(request_id : string) ~(uri : string) :
    (string, string) result =
  let headers =
    json_headers
      (("Accept", "application/json, text/event-stream")
      :: ("Mcp-Session-Id", sanitize_header_value session_id)
      :: auth_headers ())
  in
  let body = Masc_tui_mcp.resources_read_request_body ~request_id ~uri in
  match http_post ~headers ~host ~port ~path:mcp_path ~body with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status)
    ->
      Error (Printf.sprintf "resources/read returned %d: %s" status body)
  | Ok (_, body) -> Masc_tui_mcp.resource_text_of_body ~request_id body

(** POST /api/v1/keepers/:name/github-login — the device-flow login as the
    server streams it: gh's own (redacted) output, then an error or the
    final identity observation. Every chunk reaches [on_chunk] as it
    arrives; the return says only how the stream ended. *)
let post_keeper_github_login_streaming ~clock ~(host : string) ~(port : int)
    ~(keeper_name : string) ~(on_chunk : string -> unit) :
    (unit, string) result =
  let url =
    url_of ~host ~port
      ~path:
        (Printf.sprintf "/api/v1/keepers/%s/github-login"
           (percent_encode_path_segment keeper_name))
  in
  let headers =
    json_headers (("Accept", "text/event-stream") :: auth_headers ())
  in
  match
    Masc_http_client.post_stream ~clock ~idle_timeout_sec:900.0 ~url ~headers
      ~body:"{}" ~on_chunk ()
  with
  | Error detail -> Error detail
  | Ok (Masc_http_client.Pool.Buffered { status; body; _ }) ->
      Error (Printf.sprintf "github-login returned %d: %s" status body)
  | Ok (Masc_http_client.Pool.Streamed _) -> Ok ()

(** Fetch what the working tree holds for one file ([GET /api/v1/git/diff]).

    The other half of the diff story. A file change says what a keeper tried
    to write and carries no line numbers, because an [Edit] records two pieces
    of text and not where in the file they sit. This says what is in the tree
    now, with the numbers git computed.

    [keeper] names whose playground the path is read under, and the path is
    relative to that playground -- the same address the Changes surface
    already shows. Without a keeper the server reads the project checkout. *)
let fetch_git_diff ~(host : string) ~(port : int) ~(keeper : string option)
    ~(path : string) ~(base_ref : string) :
    (Masc.Tui_decode.git_diff, string) result =
  let query =
    [ Some (Printf.sprintf "path=%s" (percent_encode_query_value path))
    ; Some (Printf.sprintf "base_ref=%s" (percent_encode_query_value base_ref))
    ; Option.map
        (fun name ->
          Printf.sprintf "keeper=%s" (percent_encode_query_value name))
        keeper
    ]
    |> List.filter_map Fun.id
    |> String.concat "&"
  in
  let request_path = "/api/v1/git/diff?" ^ query in
  match http_get ~host ~port ~path:request_path with
  | Error detail -> Error detail
  | Ok (status, body) when not (Masc.Tui_decode.is_success_http_status status)
    ->
      Error (Printf.sprintf "git diff returned %d: %s" status body)
  | Ok (_, body) -> (
      match Yojson.Safe.from_string body with
      | json -> Masc.Tui_decode.decode_git_diff json
      | exception Yojson.Json_error detail ->
          Error ("git diff was not JSON: " ^ detail))
