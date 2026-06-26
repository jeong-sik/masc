(** TUI HTTP client — thin Unix.open_connection wrapper for Dashboard APIs. *)

let report_err prefix msg = Printf.sprintf "(%s: %s)" prefix msg

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

let render_headers headers =
  headers
  |> List.filter_map (fun (name, value) ->
         let value = sanitize_header_value value in
         if value = "" then None
         else Some (Printf.sprintf "%s: %s\r\n" name value))
  |> String.concat ""

let resolve_addr ~(host : string) ~(port : int) : (Unix.sockaddr, string) result =
  try
    match
      Unix.getaddrinfo host (string_of_int port)
        [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
    with
    | [] -> Error (report_err "connection failed" "host resolved to no addresses")
    | addrs -> (
        match
          List.find_map
            (fun addr ->
              match addr.Unix.ai_addr with
              | Unix.ADDR_INET _ as inet -> Some inet
              | _ -> None)
            addrs
        with
        | Some addr -> Ok addr
        | None ->
            Error
              (report_err "connection failed"
                 "host resolved to no TCP/IP addresses"))
  with
  | Unix.Unix_error (err, _, _) ->
      Error (report_err "connection failed" (Unix.error_message err))
  | exn ->
      Error (report_err "connection failed" (Printexc.to_string exn))

(** Send an HTTP GET request and return the raw response. *)
let http_get ~(host : string) ~(port : int) ~(path : string) : (string, string) result =
  match resolve_addr ~host ~port with
  | Error e -> Error e
  | Ok addr -> (
    try
    let (ic, oc) = Unix.open_connection addr in
    Fun.protect
      ~finally:(fun () ->
        Unix.shutdown_connection ic;
        close_in_noerr ic;
        close_out_noerr oc)
      (fun () ->
        let request =
          Printf.sprintf
            "GET %s HTTP/1.1\r\n\
             Host: %s:%d\r\n\
             Connection: close\r\n\
             \r\n"
            path host port
        in
        output_string oc request;
        flush oc;
        let buf = Buffer.create 4096 in
        (try while true do
           let line = input_line ic in
           Buffer.add_string buf line;
           Buffer.add_char buf '\n'
         done with End_of_file -> ());
        Ok (Buffer.contents buf))
  with
  | Unix.Unix_error (err, _, _) ->
      Error (report_err "connection failed" (Unix.error_message err))
  | exn ->
      Error (report_err "error" (Printexc.to_string exn)))

(** Send an HTTP POST request with a JSON body and return the raw response. *)
let http_post ?(headers = []) ~(host : string) ~(port : int) ~(path : string)
    ~(body : string) : (string, string) result =
  match resolve_addr ~host ~port with
  | Error e -> Error e
  | Ok addr -> (
    try
    let (ic, oc) = Unix.open_connection addr in
    Fun.protect
      ~finally:(fun () ->
        Unix.shutdown_connection ic;
        close_in_noerr ic;
        close_out_noerr oc)
      (fun () ->
        let body_len = String.length body in
        let request =
          Printf.sprintf
            "POST %s HTTP/1.1\r\n\
             Host: %s:%d\r\n\
             Content-Type: application/json\r\n\
             Content-Length: %d\r\n\
             %s\
             Connection: close\r\n\
             \r\n\
             %s"
            path host port body_len (render_headers headers) body
        in
        output_string oc request;
        flush oc;
        let buf = Buffer.create 4096 in
        (try while true do
           let line = input_line ic in
           Buffer.add_string buf line;
           Buffer.add_char buf '\n'
         done with End_of_file -> ());
        Ok (Buffer.contents buf))
  with
  | Unix.Unix_error (err, _, _) ->
      Error (report_err "connection failed" (Unix.error_message err))
  | exn ->
      Error (report_err "error" (Printexc.to_string exn)))

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
