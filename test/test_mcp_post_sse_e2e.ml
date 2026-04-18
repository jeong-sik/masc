open Alcotest

module U = Yojson.Safe.Util

type http_result = {
  status : int option;
  body : string;
  curl_exit : int;
  stderr : string;
}

let read_all ic =
  let buf = Buffer.create 1024 in
  (try
     while true do
       Buffer.add_channel buf ic 4096
     done
   with End_of_file -> ());
  Buffer.contents buf

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let trim_cr s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s

let parse_status header_raw =
  let lines = String.split_on_char '\n' header_raw |> List.map trim_cr in
  let rec find_http = function
    | [] -> None
    | line :: rest ->
        if String.length line >= 5 && String.sub line 0 5 = "HTTP/" then
          match String.split_on_char ' ' line with
          | _proto :: code :: _ -> (try Some (int_of_string code) with _ -> None)
          | _ -> None
        else
          find_http rest
  in
  find_http lines

let run_curl_post ?(max_time_sec = 8) ~port ~path ~session_id ~payload () =
  let header_file = Filename.temp_file "mcp-post-sse-header-" ".txt" in
  let body_file = Filename.temp_file "mcp-post-sse-body-" ".txt" in
  let data_file = Filename.temp_file "mcp-post-sse-request-" ".json" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let oc = open_out_bin data_file in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc payload);
  let args =
    [|
      "curl";
      "-sS";
      "-N";
      "--http1.1";
      "--max-time";
      string_of_int max_time_sec;
      "-X";
      "POST";
      "-H";
      "Content-Type: application/json";
      "-H";
      "Accept: application/json, text/event-stream";
      "-H";
      Printf.sprintf "Mcp-Session-Id: %s" session_id;
      "-H";
      "Mcp-Protocol-Version: 2025-11-25";
      "-o";
      body_file;
      "-D";
      header_file;
      "--data-binary";
      "@" ^ data_file;
      url;
    |]
  in
  let (ic, oc2, ec) =
    Unix.open_process_args_full "curl" args (Unix.environment ())
  in
  close_out_noerr oc2;
  let _stdout = read_all ic in
  let stderr = read_all ec in
  let curl_exit =
    match Unix.close_process_full (ic, oc2, ec) with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED code -> 128 + code
    | Unix.WSTOPPED code -> 256 + code
  in
  let status = parse_status (read_file header_file) in
  let body = read_file body_file in
  (try Sys.remove header_file with _ -> ());
  (try Sys.remove body_file with _ -> ());
  (try Sys.remove data_file with _ -> ());
  { status; body; curl_exit; stderr }

let run_curl_get ?(max_time_sec = 1) ~port ~path () =
  let header_file = Filename.temp_file "mcp-post-sse-get-header-" ".txt" in
  let body_file = Filename.temp_file "mcp-post-sse-get-body-" ".txt" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let args =
    [|
      "curl";
      "-sS";
      "--http1.1";
      "--max-time";
      string_of_int max_time_sec;
      "-X";
      "GET";
      "-o";
      body_file;
      "-D";
      header_file;
      url;
    |]
  in
  let (ic, oc, ec) =
    Unix.open_process_args_full "curl" args (Unix.environment ())
  in
  close_out_noerr oc;
  let _stdout = read_all ic in
  let stderr = read_all ec in
  let curl_exit =
    match Unix.close_process_full (ic, oc, ec) with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED code -> 128 + code
    | Unix.WSTOPPED code -> 256 + code
  in
  let status = parse_status (read_file header_file) in
  let body = read_file body_file in
  (try Sys.remove header_file with _ -> ());
  (try Sys.remove body_file with _ -> ());
  { status; body; curl_exit; stderr }

let contains_substr needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  n = 0 || loop 0

let normalize_mcp_body body =
  let lines = String.split_on_char '\n' body |> List.map trim_cr in
  let prefix = "data: " in
  let prefix_len = String.length prefix in
  let data_lines =
    List.filter_map
      (fun line ->
        if String.length line >= prefix_len
           && String.sub line 0 prefix_len = prefix
        then
          Some (String.sub line prefix_len (String.length line - prefix_len))
        else
          None)
      lines
  in
  match List.rev data_lines with
  | last :: _ -> last
  | [] -> body

let find_main_eio_exe () =
  let env_override = Sys.getenv_opt "MASC_MAIN_EIO_EXE" in
  let candidates =
    match env_override with
    | Some p -> [ p ]
    | None ->
        let build_roots = [ "."; ".."; "../.."; "../../.."; "../../../.." ] in
        let build_candidates =
          List.map
            (fun root -> Filename.concat root "_build/default/bin/main_eio.exe")
            build_roots
        in
        [
          "./bin/main_eio.exe";
          "../bin/main_eio.exe";
          "../../bin/main_eio.exe";
          "../../../bin/main_eio.exe";
          "../../../../bin/main_eio.exe";
        ]
        @ build_candidates
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None ->
      fail
        "main_eio executable not found. Set MASC_MAIN_EIO_EXE or build with `dune build bin/main_eio.exe`."

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
      | () -> (
          match Unix.getsockname socket with
          | Unix.ADDR_INET (_, port) -> Some port
          | _ -> fail "unexpected socket address")
      | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) ->
          None)

let wait_for_health ~port ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if Unix.gettimeofday () > deadline then
      false
    else
      let res = run_curl_get ~max_time_sec:1 ~port ~path:"/health" () in
      match res.status with
      | Some 200 when contains_substr "\"state_ready\":true" res.body -> true
      | _ ->
          Unix.sleepf 0.1;
          loop ()
  in
  loop ()

let wait_pid_exit ~pid ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
        if Unix.gettimeofday () > deadline then false
        else (
          Unix.sleepf 0.05;
          loop ())
    | _pid, _status -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  loop ()

let merge_env_overrides overrides =
  let override_keys = List.map fst overrides in
  let is_override_key entry =
    match String.index_opt entry '=' with
    | None -> false
    | Some idx ->
        let key = String.sub entry 0 idx in
        List.mem key override_keys
  in
  let base =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry -> not (is_override_key entry))
  in
  let injected = List.map (fun (k, v) -> k ^ "=" ^ v) overrides in
  Array.of_list (base @ injected)

let with_server f =
  let exe = find_main_eio_exe () in
  let port =
    match find_free_port () with
    | Some p -> p
    | None -> Alcotest.skip ()
  in
  let log_file = Filename.temp_file "mcp-post-sse-e2e-" ".log" in
  let base_path = Filename.temp_file "mcp-post-sse-base-" "" in
  (try Sys.remove base_path with _ -> ());
  Unix.mkdir base_path 0o755;
  let log_fd =
    Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
  in
  let env =
    merge_env_overrides
      [
        ("MASC_AUTONOMY_ENABLED", "0");
        ("GRAPHQL_API_KEY", "");
        ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
        ("MASC_POSTGRES_URL", "");
        ("DATABASE_URL", "");
        ("SUPABASE_DB_URL", "");
        ("SB_PG_URL", "");
        ("MASC_BOARD_BACKEND", "jsonl");
        ("MASC_POST_SSE_KEEPALIVE_SEC", "1.0");
      ]
  in
  let argv =
    [| exe; "--port"; string_of_int port; "--base-path"; base_path |]
  in
  let pid = Unix.create_process_env exe argv env Unix.stdin log_fd log_fd in
  Unix.close log_fd;
  let cleanup () =
    (try Unix.kill pid Sys.sigterm with _ -> ());
    if not (wait_pid_exit ~pid ~timeout_s:2.0) then
      (try Unix.kill pid Sys.sigkill with _ -> ());
    ignore (wait_pid_exit ~pid ~timeout_s:1.0)
  in
  if not (wait_for_health ~port ~timeout_s:20.0) then (
    cleanup ();
    let logs = read_file log_file in
    fail (Printf.sprintf "server failed to become ready on port %d\n%s" port logs)
  );
  Fun.protect ~finally:cleanup (fun () -> f ~port)

let require_http_ok label result =
  match result.status with
  | Some 200 -> ()
  | Some code ->
      fail
        (Printf.sprintf "%s returned HTTP %d (curl_exit=%d stderr=%s body=%s)"
           label code result.curl_exit result.stderr result.body)
  | None ->
      fail
        (Printf.sprintf "%s missing HTTP status (curl_exit=%d stderr=%s body=%s)"
           label result.curl_exit result.stderr result.body)

let parse_json_body label result =
  require_http_ok label result;
  let normalized = normalize_mcp_body result.body in
  try Yojson.Safe.from_string normalized
  with Yojson.Json_error err ->
    fail
      (Printf.sprintf "%s invalid JSON: %s\nbody=%s\nnormalized=%s" label err
         result.body normalized)

let tool_payload ~id ~name ~arguments =
  Yojson.Safe.to_string
    (`Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Int id);
        ("method", `String "tools/call");
        ( "params",
          `Assoc
            [ ("name", `String name); ("arguments", arguments) ] );
      ])

let rec call_status_until_ready ~port ~retries_left =
  let result =
    run_curl_post ~max_time_sec:8 ~port ~path:"/mcp"
      ~session_id:"post-sse-keepalive"
      ~payload:
        (tool_payload ~id:201 ~name:"masc_status" ~arguments:(`Assoc []))
      ()
  in
  match (result.status, retries_left) with
  | Some 500, retries
    when retries > 0
         && contains_substr "Server state not initialized" result.body ->
      Unix.sleepf 0.5;
      call_status_until_ready ~port ~retries_left:(retries - 1)
  | Some 503, retries
    when retries > 0
         && contains_substr "Server is starting up, not ready yet" result.body ->
      Unix.sleepf 0.5;
      call_status_until_ready ~port ~retries_left:(retries - 1)
  | _ -> result

(* Issue #8446: public /mcp streamable POST guarantees SSE framing for
   tools/call, but not a 30s transport keepalive inside an 8s E2E window.
   Use a valid public tool and assert prime-event + message framing instead
   of a stale keepalive contract tied to removed masc_listen. *)
let test_post_tools_call_streams_sse_framing () =
  with_server @@ fun ~port ->
  let result = call_status_until_ready ~port ~retries_left:40 in
  require_http_ok "streaming tools/call" result;
  check int "curl exits cleanly" 0 result.curl_exit;
  check bool "prime event sent" true (contains_substr "retry: 3000" result.body);
  check bool "message event sent" true
    (contains_substr "event: message" result.body);
  let json = parse_json_body "streaming tools/call" result in
  check bool "json-rpc error absent" true (json |> U.member "error" = `Null);
  check bool "tool succeeded" false
    (json |> U.member "result" |> U.member "isError" |> U.to_bool);
  let text =
    json |> U.member "result" |> U.member "content" |> U.index 0
    |> U.member "text" |> U.to_string
  in
  check bool "status text present" true (String.length text > 0)

let () =
  run "mcp_post_sse_e2e"
    [
      ( "mcp",
        [
          test_case "post tools/call streams sse framing" `Slow
            test_post_tools_call_streams_sse_framing;
        ] );
    ]
