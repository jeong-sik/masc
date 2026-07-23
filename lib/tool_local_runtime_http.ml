module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

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

let trim_to_option raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then None else Some trimmed

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
      ; effective_url = trim_to_option effective_url_raw
      ; redirect_url = trim_to_option redirect_url_raw
      ; content_type = trim_to_option content_type_raw
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
  [
    "curl";
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
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:(Masc_exec.Agent_id.of_string "tool/local_runtime")
        ~raw_source:(String.concat " " (List.map Filename.quote argv))
        ~summary:"tool local runtime http get"
        ~timeout_sec:(Stdlib.Float.of_int timeout_sec)
        argv)
  in
  match status with
  | Unix.WEXITED 0 ->
      Ok (split_http_body_and_response body)
  | Unix.WEXITED code ->
      Error (Printf.sprintf "curl exit code %d for %s" code url)
  | Unix.WSIGNALED sig_num ->
      Error (Printf.sprintf "curl signal %d for %s" sig_num url)
  | Unix.WSTOPPED sig_num ->
      Error (Printf.sprintf "curl stopped %d for %s" sig_num url)

let http_get_text_with_status_with_headers ?timeout_sec ?headers ?follow_redirects
    ?max_redirects ?compressed ?max_response_bytes url =
  match
    http_get_text_response_with_headers ?timeout_sec ?headers ?follow_redirects
      ?max_redirects ?compressed ?max_response_bytes url
  with
  | Error _ as err -> err
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
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:(Masc_exec.Agent_id.of_string "tool/local_runtime")
        ~raw_source:(String.concat " " (List.map Filename.quote argv))
        ~summary:"tool local runtime http post"
        ~timeout_sec:(Stdlib.Float.of_int timeout_sec)
        argv)
  in
  match status with
  | Unix.WEXITED 0 ->
      let payload, http_status = split_http_body_and_status body in
      Ok (http_status, payload)
  | Unix.WEXITED code ->
      Error (Printf.sprintf "curl exit code %d for %s" code url)
  | Unix.WSIGNALED sig_num ->
      Error (Printf.sprintf "curl signal %d for %s" sig_num url)
  | Unix.WSTOPPED sig_num ->
      Error (Printf.sprintf "curl stopped %d for %s" sig_num url)

let http_post_json_text_with_status ~timeout_sec ~url ~body_json =
  http_post_json_text_with_status_with_headers ~timeout_sec ~url ~body_json ()

let http_post_json_with_status ~timeout_sec ~url ~body_json =
  match http_post_json_text_with_status ~timeout_sec ~url ~body_json with
  | Error _ as err -> err
  | Ok (http_status, payload) -> (
      try Ok (http_status, Yojson.Safe.from_string payload)
      with Yojson.Json_error msg ->
        Error (Printf.sprintf "invalid json from %s: %s" url msg))

let int_member json key =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> None
  | Some (`Int value) -> Some value
  | Some (`Intlit value) -> parse_int_opt value
  | Some _ -> None

let string_member json key =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> None
  | Some (`String value) -> String_util.trim_to_option value
  | Some _ -> None
