(** Tool_local_runtime_http -- HTTP helpers for local runtime probing. *)

let default_timeout_sec = 10

include Tool_local_runtime_core

type http_get_response =
  { http_status : int option
  ; effective_url : string option
  ; redirect_url : string option
  ; content_type : string option
  ; downloaded_bytes : int option
  ; body : string
  }

let curl_meta_marker = "\n--MASC-CURL-META--\n"

let curl_write_out =
  curl_meta_marker
  ^ "%{http_code}\n%{url_effective}\n%{redirect_url}\n%{content_type}\n%{size_download}"

let find_last_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 || needle_len > haystack_len then None
  else
    let rec loop idx best =
      if idx > haystack_len - needle_len then best
      else
        let best =
          if String.equal (String.sub haystack idx needle_len) needle then Some idx
          else best
        in
        loop (idx + 1) best
    in
    loop 0 None

let parse_downloaded_bytes raw =
  match parse_int_opt (String.trim raw) with
  | Some _ as value -> value
  | None -> (
      match Stdlib.float_of_string_opt (String.trim raw) with
      | Some value -> Some (int_of_float value)
      | None -> None)

let response_of_payload_and_meta payload meta =
  let lines = String.split_on_char '\n' meta in
  match lines with
  | status_raw :: effective_url_raw :: redirect_url_raw :: content_type_raw :: size_raw :: _ ->
      { http_status = parse_int_opt (String.trim status_raw)
      ; effective_url = String_util.trim_nonempty effective_url_raw
      ; redirect_url = String_util.trim_nonempty redirect_url_raw
      ; content_type = String_util.trim_nonempty content_type_raw
      ; downloaded_bytes = parse_downloaded_bytes size_raw
      ; body = payload
      }
  | _ ->
      { http_status = None
      ; effective_url = None
      ; redirect_url = None
      ; content_type = None
      ; downloaded_bytes = None
      ; body = payload
      }

let split_http_body_and_response body =
  match find_last_substring ~needle:curl_meta_marker body with
  | Some marker_idx ->
      let payload = String.sub body 0 marker_idx in
      let meta_start = marker_idx + String.length curl_meta_marker in
      let meta = String.sub body meta_start (String.length body - meta_start) in
      response_of_payload_and_meta payload meta
  | None ->
      let payload, http_status =
        match String.rindex_opt body '\n' with
        | None -> (body, None)
        | Some idx ->
            let payload = String.sub body 0 idx in
            let status_raw =
              String.sub body (idx + 1) (String.length body - idx - 1)
              |> String.trim
            in
            (payload, parse_int_opt status_raw)
      in
      { http_status
      ; effective_url = None
      ; redirect_url = None
      ; content_type = None
      ; downloaded_bytes = None
      ; body = payload
      }

let split_http_body_and_status body =
  let response = split_http_body_and_response body in
  (response.body, response.http_status)

let header_args headers =
  List.concat_map (fun (name, value) -> [ "-H"; name ^ ": " ^ value ]) headers

let max_response_args = function
  | None -> []
  | Some bytes when bytes <= 0 -> []
  | Some bytes -> [ "--max-filesize"; Int.to_string bytes ]

let curl_get_argv ?(timeout_sec = default_timeout_sec) ?(headers = [])
    ?(follow_redirects = false) ?(max_redirects = 3) ?(compressed = false)
    ?max_response_bytes url =
  let timeout_sec = max 1 timeout_sec in
  let redirect_args =
    if follow_redirects then [ "--location"; "--max-redirs"; Int.to_string max_redirects ]
    else []
  in
  let compression_args = if compressed then [ "--compressed" ] else [] in
  (* [-q] must be the first argument: it stops curl from reading the server
     user's ~/.curlrc, which could add a proxy or a netrc credential source
     to a request the model composed. *)
  [
    "curl";
    "-q";
    "-sS";
    "--http1.1";
    "--max-time";
    Int.to_string timeout_sec;
  ]
  @ compression_args
  @ redirect_args
  @ header_args headers
  @ max_response_args max_response_bytes
  @ [ "-w"; curl_write_out; url ]

let curl_post_json_argv ~timeout_sec ?(headers = []) ~url ~body_json () =
  let timeout_sec = max 1 timeout_sec in
  [
    "curl";
    "-q";
    "-sS";
    "--http1.1";
    "--max-time";
    Int.to_string timeout_sec;
    "-H";
    "Content-Type: application/json";
  ]
  @ header_args headers
  @ [ "-d"; body_json; "-w"; "\n%{http_code}"; url ]

let curl_get_argv_for_test = curl_get_argv

type transport_failure =
  | Curl_exited of int
  | Timed_out
  | Curl_signaled of int
  | Curl_stopped of int

(* Classified by the runner that produced the status: its own budget usually
   stops curl before curl's [--max-time] does, and it reports that as a
   synthesized exit, not as curl's. *)
let transport_failure_of_status status =
  match Process_eio.exit_reason_of_status status with
  | Process_eio.Completed 0 -> None
  | Process_eio.Completed code -> Some (Curl_exited code)
  | Process_eio.Timed_out -> Some Timed_out
  | Process_eio.Signaled signal -> Some (Curl_signaled signal)
  | Process_eio.Stopped signal -> Some (Curl_stopped signal)
;;

let transport_failure_to_string ~url = function
  | Curl_exited code -> Printf.sprintf "curl exit code %d for %s" code url
  | Timed_out -> Printf.sprintf "curl timed out for %s" url
  | Curl_signaled signal -> Printf.sprintf "curl signal %d for %s" signal url
  | Curl_stopped signal -> Printf.sprintf "curl stopped %d for %s" signal url
;;

(* The causes a fetch meets, in curl(1) EXIT CODES wording. Any other code
   is reported by number. *)
let curl_exit_cause = function
  | 6 -> Some "could not resolve host"
  | 7 -> Some "could not connect"
  | 28 -> Some "timed out"
  | 35 -> Some "TLS handshake failed"
  | 52 -> Some "empty reply from server"
  | 56 -> Some "failure receiving network data"
  | 60 -> Some "peer certificate verification failed"
  | 63 -> Some "response larger than the size limit"
  | _ -> None
;;

(* Signal numbers from [Unix.WSIGNALED] are OCaml's own ([Sys.sigkill] is -7),
   so the model is told only that a signal ended curl. *)
let transport_failure_cause = function
  | Curl_exited code ->
    (match curl_exit_cause code with
     | Some cause -> Printf.sprintf "curl exit %d (%s)" code cause
     | None -> Printf.sprintf "curl exit %d" code)
  | Timed_out -> "timed out before curl answered"
  | Curl_signaled _ -> "curl was killed by a signal"
  | Curl_stopped _ -> "curl was stopped by a signal"
;;

let http_get_text_response_with_headers ?(timeout_sec = default_timeout_sec)
    ?(headers = []) ?(follow_redirects = false) ?(max_redirects = 3)
    ?(compressed = false) ?max_response_bytes url =
  let timeout_sec = max 1 timeout_sec in
  let argv =
    curl_get_argv ~timeout_sec ~headers ~follow_redirects ~max_redirects
      ~compressed ?max_response_bytes url
  in
  let status, body =
    Fd_accountant.observe ~kind:Sandbox_exec (fun () ->
      Process_eio.run_argv_with_status
        ~timeout_sec:(Stdlib.Float.of_int timeout_sec)
        argv)
  in
  match transport_failure_of_status status with
  | None -> Ok (split_http_body_and_response body)
  | Some failure -> Error failure

let http_get_text_with_status_with_headers ?timeout_sec ?headers ?follow_redirects
    ?max_redirects ?compressed ?max_response_bytes url =
  match
    http_get_text_response_with_headers ?timeout_sec ?headers ?follow_redirects
      ?max_redirects ?compressed ?max_response_bytes url
  with
  | Error failure -> Error (transport_failure_to_string ~url failure)
  | Ok response -> Ok (response.http_status, response.body)

let http_get_text_with_status ?timeout_sec url =
  http_get_text_with_status_with_headers ?timeout_sec url

let http_get_json_with_status ?(timeout_sec = default_timeout_sec) url =
  match http_get_text_with_status ~timeout_sec url with
  | Error _ as err -> err
  | Ok (http_status, payload) -> (
      try Ok (http_status, Yojson.Safe.from_string payload)
      with Yojson.Json_error msg ->
        Error (Printf.sprintf "invalid json from %s: %s" url msg))

let http_post_json_text_with_status_with_headers ~timeout_sec ?(headers = []) ~url
    ~body_json () =
  let timeout_sec = max 1 timeout_sec in
  let argv = curl_post_json_argv ~timeout_sec ~headers ~url ~body_json () in
  let status, body =
    Fd_accountant.observe ~kind:Sandbox_exec (fun () ->
      Process_eio.run_argv_with_status
        ~timeout_sec:(Stdlib.Float.of_int timeout_sec)
        argv)
  in
  match transport_failure_of_status status with
  | None ->
      let payload, http_status = split_http_body_and_status body in
      Ok (http_status, payload)
  | Some failure -> Error (transport_failure_to_string ~url failure)

let http_post_json_text_with_status ~timeout_sec ~url ~body_json =
  http_post_json_text_with_status_with_headers ~timeout_sec ~url ~body_json ()

let int_member json key =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> None
  | Some (`Int value) -> Some value
  | Some (`Intlit value) -> parse_int_opt value
  | Some _ -> None

let string_member json key =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> None
  | Some (`String value) -> String_util.trim_nonempty value
  | Some _ -> None
