(** TUI HTTP client — Dashboard API wrapper over Masc_http_client. *)

let report_err prefix msg = Printf.sprintf "(%s: %s)" prefix msg
let default_timeout_sec = 10.0

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let first_nonempty_env names =
  List.find_map (fun name -> Option.bind (Sys.getenv_opt name) trim_nonempty) names

let sanitize_header_value value =
  value
  |> String.map (function
       | '\r' | '\n' -> ' '
       | c -> c)
  |> String.trim

let default_agent_name () =
  first_nonempty_env [ "MASC_TUI_AGENT"; "MASC_AGENT" ]
  |> Option.value ~default:"masc-tui"
  |> sanitize_header_value

let auth_headers () =
  let agent_header = [ ("X-MASC-Agent", default_agent_name ()) ] in
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

let raw_response ~status ~body = Printf.sprintf "HTTP/1.1 %d\r\n\r\n%s" status body

let request_clock () = Eio_context.get_clock_opt ()

(** Send an HTTP GET request and return the raw response. *)
let http_get ~(host : string) ~(port : int) ~(path : string) : (string, string) result =
  let url = url_of ~host ~port ~path in
  match
    Masc_http_client.get_sync ?clock:(request_clock ()) ~timeout_sec:default_timeout_sec
      ~url ~headers:(auth_headers ()) ()
  with
  | Ok (status, body) ->
      if Masc.Tui_decode.is_success_http_status status then
        Ok (raw_response ~status ~body)
      else Error (Printf.sprintf "HTTP error %d: %s" status body)
  | Error e -> Error (report_err "GET failed" e)

(** Send an HTTP POST request with a JSON body and return the raw response. *)
let http_post ?(headers = []) ~(host : string) ~(port : int) ~(path : string)
    ~(body : string) : (string, string) result =
  let url = url_of ~host ~port ~path in
  match
    Masc_http_client.post_sync ?clock:(request_clock ())
      ~timeout_sec:default_timeout_sec ~url ~headers:(json_headers headers) ~body
      ()
  with
  | Ok (status, body) ->
      if Masc.Tui_decode.is_success_http_status status then
        Ok (raw_response ~status ~body)
      else Error (Printf.sprintf "HTTP error %d: %s" status body)
  | Error e -> Error (report_err "POST failed" e)

(** GET a JSON response from a dashboard endpoint. *)
let get_json ~(host : string) ~(port : int) ~(path : string) : (Yojson.Safe.t, string) result =
  match http_get ~host ~port ~path with
  | Error e -> Error e
  | Ok raw -> Masc.Tui_decode.decode_json_http_response ~allow_empty:false raw

(** POST a JSON body and parse the JSON response. *)
let post_json ~(host : string) ~(port : int) ~(path : string) ~(body : string) : (Yojson.Safe.t, string) result =
  match http_post ~headers:(auth_headers ()) ~host ~port ~path ~body with
  | Error e -> Error e
  | Ok raw -> Masc.Tui_decode.decode_json_http_response ~allow_empty:true raw

let post_raw_json ~(host : string) ~(port : int) ~(path : string) ~(body : string) :
    (string, string) result =
  match http_post ~headers:(auth_headers ()) ~host ~port ~path ~body with
  | Error e -> Error e
  | Ok raw -> (
      match Masc.Tui_decode.parse_http_response raw with
      | Error e -> Error e
      | Ok response
        when Masc.Tui_decode.is_success_http_status response.status_code ->
          Ok raw
      | Ok response -> Error (Masc.Tui_decode.http_status_error response))

(** Fetch /api/v1/dashboard/briefing (Mission / Overview snapshot). *)
let fetch_dashboard_briefing ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/dashboard/briefing"

(** POST /api/v1/operator/confirm to approve/deny a pending confirmation. *)
let operator_confirm_body ~(token : string) ~(decision : string) =
  Yojson.Safe.to_string
    (`Assoc [ ("confirm_token", `String token); ("decision", `String decision) ])

let post_operator_confirm ~(host : string) ~(port : int) ~(token : string) ~(decision : string) : (Yojson.Safe.t, string) result =
  let body = operator_confirm_body ~token ~decision in
  post_json ~host ~port ~path:"/api/v1/operator/confirm" ~body

(** Fetch /api/v1/board (post list). *)
let fetch_board ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/board"

(** Fetch /api/v1/board/<postId> (post detail + comments). *)
let fetch_board_post ~(host : string) ~(port : int) ~(post_id : string) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:(Printf.sprintf "/api/v1/board/%s?format=flat" (String.escaped post_id))

(** Fetch /api/v1/dashboard/planning (goals + rollup + task backlog). *)
let fetch_dashboard_planning ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/dashboard/planning"

(** Check if a server is reachable on the configured host/port. *)
let server_reachable ~(host : string) ~(port : int) : bool =
  match http_get ~host ~port ~path:"/api/v1/dashboard/shell" with
  | Ok raw -> (
      match Masc.Tui_decode.parse_http_response raw with
      | Ok response -> Masc.Tui_decode.is_success_http_status response.status_code
      | Error _ -> false)
  | Error _ -> false
