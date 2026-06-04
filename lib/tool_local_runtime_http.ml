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


let split_http_body_and_status body =
  match String.rindex_opt body '\n' with
  | None -> (body, None)
  | Some idx ->
      let payload = String.sub body 0 idx in
      let status_raw =
        String.sub body (idx + 1) (String.length body - idx - 1) |> String.trim
      in
      (payload, parse_int_opt status_raw)

let header_args headers =
  List.concat_map (fun (name, value) -> [ "-H"; name ^ ": " ^ value ]) headers

let max_response_args = function
  | None -> []
  | Some bytes when bytes <= 0 -> []
  | Some bytes ->
      [
        "--max-filesize";
        Int.to_string bytes;
        "--range";
        "0-" ^ Int.to_string (bytes - 1);
      ]

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
  @ [ "-w"; "\n%{http_code}"; url ]

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

let http_get_text_with_status_with_headers ?(timeout_sec = default_timeout_sec)
    ?(headers = []) ?(follow_redirects = false) ?(max_redirects = 3)
    ?(compressed = false) ?max_response_bytes url =
  let timeout_sec = max 1 timeout_sec in
  let argv =
    curl_get_argv ~timeout_sec ~headers ~follow_redirects ~max_redirects
      ~compressed ?max_response_bytes url
  in
  let status, body =
    Fd_accountant.with_slot ~kind:Sandbox_exec (fun () ->
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:(Masc_exec.Agent_id.of_string "tool/local_runtime")
        ~raw_source:(String.concat " " (List.map Filename.quote argv))
        ~summary:"tool local runtime http get"
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
    Fd_accountant.with_slot ~kind:Sandbox_exec (fun () ->
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
