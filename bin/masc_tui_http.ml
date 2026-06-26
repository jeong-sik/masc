(** TUI HTTP client — thin Unix.open_connection wrapper for Dashboard APIs. *)

let report_err prefix msg = Printf.sprintf "(%s: %s)" prefix msg

(** Send an HTTP GET request and return the raw response. *)
let http_get ~(host : string) ~(port : int) ~(path : string) : (string, string) result =
  try
    let addr = Unix.ADDR_INET (Unix.inet_addr_of_string host, port) in
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
      Error (report_err "error" (Printexc.to_string exn))

(** Send an HTTP POST request with a JSON body and return the raw response. *)
let http_post ~(host : string) ~(port : int) ~(path : string) ~(body : string) : (string, string) result =
  try
    let addr = Unix.ADDR_INET (Unix.inet_addr_of_string host, port) in
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
             Connection: close\r\n\
             \r\n\
             %s"
            path host port body_len body
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
      Error (report_err "error" (Printexc.to_string exn))

(** Extract the body from a simple HTTP/1.1 response.
    Does not handle chunked transfer-encoding. *)
let extract_body (response : string) : (string, string) result =
  let lines = String.split_on_char '\n' response in
  let rec find_empty = function
    | [] -> Error "no empty line in HTTP response"
    | "" :: xs -> Ok (String.concat "\n" xs)
    | line :: xs when String.length line > 0 && line.[String.length line - 1] = '\r' ->
        let stripped = String.sub line 0 (String.length line - 1) in
        if stripped = "" then Ok (String.concat "\n" xs)
        else find_empty xs
    | _ :: xs -> find_empty xs
  in
  find_empty lines

(** GET a JSON response from a dashboard endpoint. *)
let get_json ~(host : string) ~(port : int) ~(path : string) : (Yojson.Safe.t, string) result =
  match http_get ~host ~port ~path with
  | Error e -> Error e
  | Ok raw ->
      match extract_body raw with
      | Error e -> Error e
      | Ok body ->
          if String.length (String.trim body) = 0 then Error "empty response body"
          else (
            try Ok (Yojson.Safe.from_string body)
            with Yojson.Json_error e -> Error (report_err "JSON parse" e))

(** POST a JSON body and parse the JSON response. *)
let post_json ~(host : string) ~(port : int) ~(path : string) ~(body : string) : (Yojson.Safe.t, string) result =
  match http_post ~host ~port ~path ~body with
  | Error e -> Error e
  | Ok raw ->
      match extract_body raw with
      | Error e -> Error e
      | Ok body ->
          if String.length (String.trim body) = 0 then Ok (`Assoc [])
          else (
            try Ok (Yojson.Safe.from_string body)
            with Yojson.Json_error e -> Error (report_err "JSON parse" e))

(** Fetch /api/v1/dashboard/briefing (Mission / Overview snapshot). *)
let fetch_dashboard_briefing ~(host : string) ~(port : int) : (Yojson.Safe.t, string) result =
  get_json ~host ~port ~path:"/api/v1/dashboard/briefing"

(** POST /api/v1/operator/confirm to approve/deny a pending confirmation. *)
let post_operator_confirm ~(host : string) ~(port : int) ~(token : string) ~(decision : string) : (Yojson.Safe.t, string) result =
  let body =
    Printf.sprintf {|{"confirm_token":"%s","decision":"%s"}|}
      (String.escaped token)
      (String.escaped decision)
  in
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
  | Ok _ -> true
  | Error _ -> false
