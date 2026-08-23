(** TUI HTTP client — Dashboard API wrapper over Masc_http_client. *)

let report_err prefix msg = Printf.sprintf "(%s: %s)" prefix msg
let default_timeout_sec = 10.0
let request_timeout_sec () = default_timeout_sec
let keeper_chat_timeout_sec = 180.0

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
  let url = url_of ~host ~port ~path:"/api/v1/keepers/chat/stream" in
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

(** Fetch /api/v1/board/<postId> (post detail + comments). *)
let fetch_board_post ~(host : string) ~(port : int) ~(post_id : string) : (Yojson.Safe.t, string) result =
  get_json ~host ~port
    ~path:
      (Printf.sprintf "/api/v1/board/%s?format=flat"
         (percent_encode_path_segment post_id))

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
