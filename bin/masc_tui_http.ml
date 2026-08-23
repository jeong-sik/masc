(** TUI HTTP client — Dashboard API wrapper over Masc_http_client. *)

let report_err prefix msg = Printf.sprintf "(%s: %s)" prefix msg
let default_timeout_sec = 10.0
let request_timeout_sec () = default_timeout_sec
let keeper_chat_timeout_sec = 180.0

(* One name for the send target. The buffered send and the streaming send are
   two ways of reading the same turn, not two endpoints, and a contract test
   pins that this literal appears once so they cannot drift apart. *)
let keeper_chat_stream_path = "/api/v1/keepers/chat/stream"
let keeper_turn_interrupt_path = "/api/v1/keepers/turn/interrupt"
let keeper_tool_approval_path = "/api/v1/keepers/tool-approval"

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

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

let default_agent_name = "masc-tui"

let auth_headers () =
  let agent_header = [ ("X-MASC-Agent", default_agent_name) ] in
  match first_nonempty_env [ "MASC_TOKEN" ] with
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

(** GET a JSON response from a dashboard endpoint. *)
let get_json ~(host : string) ~(port : int) ~(path : string) : (Yojson.Safe.t, string) result =
  match http_get ~host ~port ~path with
  | Error e -> Error e
  | Ok (status_code, body) ->
      Masc.Tui_decode.decode_json_response_body ~allow_empty:false ~status_code
        ~body

(** POST a JSON body and parse the JSON response. *)
let post_json ~(host : string) ~(port : int) ~(path : string) ~(body : string) : (Yojson.Safe.t, string) result =
  match http_post ~headers:(auth_headers ()) ~host ~port ~path ~body with
  | Error e -> Error e
  | Ok (status_code, body) ->
      Masc.Tui_decode.decode_json_response_body ~allow_empty:true ~status_code
        ~body

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

(** Fetch /api/v1/board/<postId> (post detail + comments). *)
let fetch_board_post ~(host : string) ~(port : int) ~(post_id : string) : (Yojson.Safe.t, string) result =
  get_json ~host ~port
    ~path:
      (Printf.sprintf "/api/v1/board/%s?format=flat"
         (percent_encode_path_segment post_id))

(** Fetch /api/v1/dashboard/logs. The server caps [limit] at 3000; the TUI asks
    for a screenful's worth of history rather than the whole ring. *)
let fetch_dashboard_logs ~(host : string) ~(port : int) ~(limit : int) :
    (Yojson.Safe.t, string) result =
  get_json ~host ~port
    ~path:(Printf.sprintf "/api/v1/dashboard/logs?limit=%d" (max 1 (min 3000 limit)))

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
