open Alcotest

type http_result = {
  status: int option;
  headers: (string * string) list;
  body: string;
  curl_exit: int;
  stderr: string;
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

let parse_headers raw =
  let lines = String.split_on_char '\n' raw |> List.map trim_cr in
  let rec collect blocks current = function
    | [] ->
        let blocks =
          if current = [] then blocks else List.rev current :: blocks
        in
        List.rev blocks
    | line :: rest ->
        if line = "" then
          let blocks =
            if current = [] then blocks else List.rev current :: blocks
          in
          collect blocks [] rest
        else
          collect blocks (line :: current) rest
  in
  let blocks = collect [] [] lines in
  let last_http_block =
    List.fold_left
      (fun acc block ->
         match block with
         | status_line :: _ when String.length status_line >= 5
                                && String.sub status_line 0 5 = "HTTP/" ->
             Some block
         | _ -> acc)
      None blocks
  in
  match last_http_block with
  | None -> (None, [])
  | Some (status_line :: header_lines) ->
      let status =
        match String.split_on_char ' ' status_line with
        | _proto :: code :: _ -> (try Some (int_of_string code) with _ -> None)
        | _ -> None
      in
      let headers =
        List.filter_map
          (fun line ->
             match String.index_opt line ':' with
             | None -> None
             | Some idx ->
                 let key =
                   String.sub line 0 idx |> String.trim |> String.lowercase_ascii
                 in
                 let value =
                   String.sub line (idx + 1) (String.length line - idx - 1)
                   |> String.trim
                 in
                 Some (key, value))
          header_lines
      in
      (status, headers)
  | Some [] -> (None, [])

let run_curl ?(headers=[]) ?max_time ?(method_="GET") ?body ~port ~path () =
  let header_file = Filename.temp_file "sse-storm-header-" ".txt" in
  let body_file = Filename.temp_file "sse-storm-body-" ".txt" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let max_time_args =
    match max_time with
    | None -> []
    | Some t -> ["--max-time"; Printf.sprintf "%.3f" t]
  in
  let header_args =
    List.concat_map
      (fun (k, v) -> ["-H"; Printf.sprintf "%s: %s" k v])
      headers
  in
  let body_args =
    match body with
    | None -> []
    | Some body -> [ "--data-binary"; body ]
  in
  let args =
    [|
      "curl";
      "-sS";
      "--http1.1";
      "-X";
      method_;
      "-o";
      body_file;
      "-D";
      header_file;
    |]
    |> Array.to_list
    |> fun base -> base @ max_time_args @ header_args @ body_args @ [url]
    |> Array.of_list
  in
  let (ic, oc, ec) = Unix.open_process_args_full "curl" args (Unix.environment ()) in
  close_out_noerr oc;
  let _stdout = read_all ic in
  let stderr = read_all ec in
  let curl_exit =
    match Unix.close_process_full (ic, oc, ec) with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED code -> 128 + code
    | Unix.WSTOPPED code -> 256 + code
  in
  let header_raw = read_file header_file in
  let body = read_file body_file in
  (try Sys.remove header_file with _ -> ());
  (try Sys.remove body_file with _ -> ());
  let (status, headers) = parse_headers header_raw in
  { status; headers; body; curl_exit; stderr }

let header_value result name =
  let name = String.lowercase_ascii name in
  result.headers
  |> List.find_map (fun (key, value) ->
    if String.equal (String.lowercase_ascii key) name then Some value else None)

let find_main_eio_exe () =
  let env_override = Sys.getenv_opt "MASC_MAIN_EIO_EXE" in
  let candidates =
    match env_override with
    | Some p -> [p]
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
        ] @ build_candidates
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
      | () ->
          begin
            match Unix.getsockname socket with
            | Unix.ADDR_INET (_, port) -> Some port
            | _ -> fail "unexpected socket address"
          end
      | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) -> None)

let wait_for_health ~port ~timeout_s =
  let has_ready_flag body =
    let needle = "\"state_ready\":true" in
    let needle_len = String.length needle in
    let body_len = String.length body in
    let rec loop idx =
      if idx + needle_len > body_len then false
      else if String.sub body idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0
  in
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if Unix.gettimeofday () > deadline then
      false
    else
      let res = run_curl ~max_time:0.2 ~port ~path:"/health" () in
      match res.status with
      | Some 200 when has_ready_flag res.body -> true
      | _ ->
          Unix.sleepf 0.1;
          loop ()
  in
  loop ()

let wait_pid_exit ~pid ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match Unix.waitpid [Unix.WNOHANG] pid with
    | 0, _ ->
        if Unix.gettimeofday () > deadline then
          false
        else begin
          Unix.sleepf 0.05;
          loop ()
        end
    | _pid, _status -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  loop ()

let dashboard_dev_token ~port =
  let result =
    run_curl ~max_time:2.0 ~port ~path:"/api/v1/dashboard/dev-token" ()
  in
  match result.status with
  | Some 200 ->
      begin
        match Yojson.Safe.from_string result.body with
        | `Assoc fields ->
            begin
              match List.assoc_opt "token" fields with
              | Some (`String token) when String.trim token <> "" -> token
              | _ -> fail ("dashboard dev-token response missing token: " ^ result.body)
            end
        | _ -> fail ("dashboard dev-token response is not an object: " ^ result.body)
        | exception Yojson.Json_error msg ->
            fail ("dashboard dev-token response is invalid JSON: " ^ msg)
      end
  | Some code ->
      fail
        (Printf.sprintf
           "dashboard dev-token returned HTTP %d (curl_exit=%d stderr=%s body=%s)"
           code result.curl_exit result.stderr result.body)
  | None ->
      fail
        (Printf.sprintf
           "dashboard dev-token missing HTTP status (curl_exit=%d stderr=%s body=%s)"
           result.curl_exit result.stderr result.body)

let initialize_mcp_session ~port ~auth_token =
  let body =
    {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"sse-storm-e2e","version":"1.0"},"capabilities":{}}}|}
  in
  let result =
    run_curl
      ~headers:
        [
          ("Content-Type", "application/json");
          ("Accept", "application/json, text/event-stream");
          ("Authorization", "Bearer " ^ auth_token);
        ]
      ~method_:"POST" ~body ~max_time:2.0 ~port ~path:"/mcp" ()
  in
  (match result.status with
  | Some 200 -> ()
  | Some code ->
      fail
        (Printf.sprintf
           "initialize returned HTTP %d (curl_exit=%d stderr=%s body=%s)"
           code result.curl_exit result.stderr result.body)
  | None ->
      fail
        (Printf.sprintf
           "initialize missing HTTP status (curl_exit=%d stderr=%s body=%s)"
           result.curl_exit result.stderr result.body));
  match header_value result "mcp-session-id" with
  | Some sid when String.trim sid <> "" -> sid
  | _ ->
      fail
        (Printf.sprintf
           "initialize response missing Mcp-Session-Id (curl_exit=%d stderr=%s body=%s)"
           result.curl_exit result.stderr result.body)

let merge_env_overrides overrides =
  let override_keys =
    List.map fst overrides
  in
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
  let injected =
    List.map (fun (k, v) -> k ^ "=" ^ v) overrides
  in
  Array.of_list (base @ injected)

let ensure_dir path =
  if Sys.file_exists path then
    if not (Sys.is_directory path) then
      fail (Printf.sprintf "expected directory path: %s" path)
    else ()
  else
    Unix.mkdir path 0o755

let find_repo_file relative =
  let roots = [ "."; ".."; "../.."; "../../.."; "../../../.." ] in
  roots
  |> List.map (fun root -> Filename.concat root relative)
  |> List.find_opt Sys.file_exists

let runtime_seed =
  {|
[runtime]
default = "sse_storm.smoke"

[providers.sse_storm]
display-name = "SSE Storm Smoke"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[models.smoke]
# The SSE storm harness never reaches this provider endpoint, but strict
# runtime bootstrap still requires catalog-backed capability metadata.
api-name = "deepseek-v4-flash"
max-context = 32768
tools-support = true
streaming = true

[sse_storm.smoke]
is-default = true
max-concurrent = 1
|}

let seed_server_config ~base_path =
  let masc_dir = Filename.concat base_path ".masc" in
  let config_dir = Filename.concat masc_dir "config" in
  ensure_dir masc_dir;
  ensure_dir config_dir;
  List.iter
    (fun name -> ensure_dir (Filename.concat config_dir name))
    [ "keepers"; "personas"; "prompts" ];
  let runtime_dst = Filename.concat config_dir "runtime.toml" in
  if not (Sys.file_exists runtime_dst) then
    let oc = open_out runtime_dst in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc runtime_seed)

let with_server f =
  let exe = find_main_eio_exe () in
  let port =
    match find_free_port () with
    | Some p -> p
    | None -> Alcotest.skip ()
  in
  let log_file = Filename.temp_file "sse-storm-e2e-" ".log" in
  let base_path = Filename.temp_file "sse-storm-base-" "" in
  (try Sys.remove base_path with _ -> ());
  Unix.mkdir base_path 0o755;
  seed_server_config ~base_path;
  let oas_model_catalog =
    match find_repo_file "oas-models.toml" with
    | Some path -> path
    | None -> fail "oas-models.toml fixture not found"
  in
  let log_fd =
    Unix.openfile log_file [Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC] 0o644
  in
  let env =
    merge_env_overrides
      [
        ("MASC_BASE_PATH", base_path);
        ("MASC_BASE_PATH_INPUT", base_path);
        ("MASC_AUTONOMY_ENABLED", "0");
        ("GRAPHQL_API_KEY", "");
        ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
        ("OAS_MODEL_CATALOG", oas_model_catalog);
      ]
  in
  let argv =
    [|
      exe;
      "--port";
      string_of_int port;
      "--base-path";
      base_path;
    |]
  in
  let pid =
    Unix.create_process_env exe argv env Unix.stdin log_fd log_fd
  in
  Unix.close log_fd;
  let cleanup () =
    (try Unix.kill pid Sys.sigterm with _ -> ());
    if not (wait_pid_exit ~pid ~timeout_s:2.0) then
      (try Unix.kill pid Sys.sigkill with _ -> ());
    ignore (wait_pid_exit ~pid ~timeout_s:1.0)
  in
  if not (wait_for_health ~port ~timeout_s:20.0) then begin
    cleanup ();
    let logs = read_file log_file in
    fail (Printf.sprintf "server failed to become ready on port %d\n%s" port logs)
  end;
  Fun.protect ~finally:cleanup (fun () ->
    let auth_token = dashboard_dev_token ~port in
    f ~port ~auth_token)

let check_status label expected result =
  match result.status with
  | Some code -> check int label expected code
  | None ->
      fail
        (Printf.sprintf
           "%s: no HTTP status (curl_exit=%d, stderr=%s)"
           label
           result.curl_exit
           result.stderr)

let test_mcp_reconnect_stays_accepted () =
  with_server @@ fun ~port ~auth_token ->
  let sid = initialize_mcp_session ~port ~auth_token in
  let headers =
    [
      ("Accept", "text/event-stream");
      ("Authorization", "Bearer " ^ auth_token);
      ("Mcp-Session-Id", sid);
    ]
  in

  let first = run_curl ~headers ~max_time:2.0 ~port ~path:"/mcp" () in
  check_status "first /mcp connect accepted" 200 first;

  let second = run_curl ~headers ~max_time:2.0 ~port ~path:"/mcp" () in
  check_status "follow-up /mcp reconnect accepted" 200 second

let test_ag_ui_rejects_reconnect_then_recovers () =
  with_server @@ fun ~port ~auth_token ->
  let sid = initialize_mcp_session ~port ~auth_token in
  (* /ag-ui/events uses the observer SSE auth path; mirror /mcp by passing the
     dashboard dev token explicitly. *)
  let headers =
    [
      ("Accept", "text/event-stream");
      ("Authorization", "Bearer " ^ auth_token);
      ("Mcp-Session-Id", sid);
    ]
  in

  (* Stay well inside the 1s reconnect guard so the next request is truly immediate. *)
  let first = run_curl ~headers ~max_time:0.2 ~port ~path:"/ag-ui/events?workspace=default" () in
  check_status "first /ag-ui/events connect accepted" 200 first;

  let second = run_curl ~headers ~max_time:0.5 ~port ~path:"/ag-ui/events?workspace=default" () in
  check_status "immediate /ag-ui/events reconnect rejected" 429 second;

  Unix.sleepf 2.0;
  let third = run_curl ~headers ~max_time:1.5 ~port ~path:"/ag-ui/events?workspace=default" () in
  check_status "cooldown /ag-ui/events reconnect recovers" 200 third

let () =
  Random.self_init ();
  run "sse_storm_e2e"
    [
      ("mcp", [test_case "follow-up reconnect accepted" `Slow test_mcp_reconnect_stays_accepted]);
      ("ag_ui", [test_case "reconnect cooldown + recovery" `Slow test_ag_ui_rejects_reconnect_then_recovers]);
    ]
