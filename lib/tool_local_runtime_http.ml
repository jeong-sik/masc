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

let trim_to_option raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then None else Some trimmed

let split_http_body_and_status body =
  match String.rindex_opt body '\n' with
  | None -> (body, None)
  | Some idx ->
      let payload = String.sub body 0 idx in
      let status_raw =
        String.sub body (idx + 1) (String.length body - idx - 1) |> String.trim
      in
      (payload, parse_int_opt status_raw)

let append_headers args headers =
  (* Accumulate header args without repeated list concatenation, then reverse
     them back so curl sees headers in the same left-to-right order as the
     input list. *)
  let header_args_rev =
    List.fold_left
      (fun acc (name, value) -> (name ^ ": " ^ value) :: "-H" :: acc)
      [] headers
  in
  List.rev_append header_args_rev args

let http_get_text_with_status_with_headers ?(timeout_sec = default_timeout_sec) ?(headers = []) url =
  let argv =
    append_headers
      [
        "curl";
        "-sS";
        "--http1.1";
        "--max-time";
        Int.to_string (max 1 timeout_sec);
        "-w";
        "\n%{http_code}";
        url;
      ]
      headers
  in
  let status, body =
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:(Masc_exec.Agent_id.of_string "tool/local_runtime")
      ~raw_source:(String.concat " " (List.map Filename.quote argv))
      ~summary:"tool local runtime http get"
      ~timeout_sec:(Stdlib.Float.of_int (max 1 timeout_sec))
      argv
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

let http_post_json_text_with_status_with_headers ~timeout_sec ?(headers = []) ~url ~body_json () =
  let argv =
    append_headers
      [
        "curl";
        "-sS";
        "--http1.1";
        "--max-time";
        Int.to_string (max 1 timeout_sec);
        "-H";
        "Content-Type: application/json";
        "-d";
        body_json;
        "-w";
        "\n%{http_code}";
        url;
      ]
      headers
  in
  let status, body =
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:(Masc_exec.Agent_id.of_string "tool/local_runtime")
      ~raw_source:(String.concat " " (List.map Filename.quote argv))
      ~summary:"tool local runtime http post"
      ~timeout_sec:(Stdlib.Float.of_int (max 1 timeout_sec))
      argv
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
  let open Yojson.Safe.Util in
  match member key json with
  | `Int value -> Some value
  | `Intlit value -> parse_int_opt value
  | _ -> None

let string_member json key =
  let open Yojson.Safe.Util in
  Option.bind (member key json |> to_string_option) trim_to_option
