module Types = Masc_domain

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

let parse_headers raw =
  let lines = String.split_on_char '\n' raw |> List.map trim_cr in
  let rec collect blocks current = function
    | [] ->
        let blocks = if current = [] then blocks else List.rev current :: blocks in
        List.rev blocks
    | line :: rest ->
        if line = "" then
          let blocks = if current = [] then blocks else List.rev current :: blocks in
          collect blocks [] rest
        else
          collect blocks (line :: current) rest
  in
  let blocks = collect [] [] lines in
  let last_http_block =
    List.fold_left
      (fun acc block ->
        match block with
        | status_line :: _
          when String.length status_line >= 5
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

let run_curl_json ?token ?(max_time_sec = 5) ~port ~path ~session_id ~payload () =
  let header_file = Filename.temp_file "operator-mcp-header-" ".txt" in
  let body_file = Filename.temp_file "operator-mcp-body-" ".txt" in
  let data_file = Filename.temp_file "operator-mcp-request-" ".json" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let oc = open_out_bin data_file in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc payload);
  let base_args =
    [
      "curl";
      "-sS";
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
      "-o";
      body_file;
      "-D";
      header_file;
      "--data-binary";
      "@" ^ data_file;
    ]
  in
  let args =
    match token with
    | None -> Array.of_list (base_args @ [ url ])
    | Some t ->
        Array.of_list
          (base_args @ [ "-H"; Printf.sprintf "Authorization: Bearer %s" t; url ])
  in
  let (ic, oc2, ec) = Unix.open_process_args_full "curl" args (Unix.environment ()) in
  close_out_noerr oc2;
  let _stdout = read_all ic in
  let stderr = read_all ec in
  let curl_exit =
    match Unix.close_process_full (ic, oc2, ec) with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED code -> 128 + code
    | Unix.WSTOPPED code -> 256 + code
  in
  let header_raw = read_file header_file in
  let body = read_file body_file in
  (try Sys.remove header_file with _ -> ());
  (try Sys.remove body_file with _ -> ());
  (try Sys.remove data_file with _ -> ());
  let (status, _headers) = parse_headers header_raw in
  { status; body; curl_exit; stderr }

let run_curl_get ~port ~path () =
  let header_file = Filename.temp_file "operator-mcp-health-header-" ".txt" in
  let body_file = Filename.temp_file "operator-mcp-health-body-" ".txt" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let args =
    [|
      "curl";
      "-sS";
      "--http1.1";
      "--max-time";
      "0.5";
      "-X";
      "GET";
      "-o";
      body_file;
      "-D";
      header_file;
      url;
    |]
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
  let (status, _headers) = parse_headers header_raw in
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
        build_candidates
        @ [
            "./bin/main_eio.exe";
            "../bin/main_eio.exe";
            "../../bin/main_eio.exe";
            "../../../bin/main_eio.exe";
            "../../../../bin/main_eio.exe";
          ]
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
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if Unix.gettimeofday () > deadline then false
    else
      let res = run_curl_get ~port ~path:"/health" () in
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
        else begin
          Unix.sleepf 0.05;
          loop ()
        end
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
    Unix.environment () |> Array.to_list
    |> List.filter (fun entry -> not (is_override_key entry))
  in
  let injected = List.map (fun (k, v) -> k ^ "=" ^ v) overrides in
  Array.of_list (base @ injected)

let jsonrpc_payload ~id ~method_name ~params =
  Yojson.Safe.to_string
    (`Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Int id);
        ("method", `String method_name);
        ("params", params);
      ])

let tools_list_payload ~id = jsonrpc_payload ~id ~method_name:"tools/list" ~params:(`Assoc [])

let require_http_ok label result =
  match result.status with
  | Some 200 -> ()
  | Some code ->
      fail
        (Printf.sprintf "%s returned HTTP %d (curl_exit=%d stderr=%s body=%s)" label
           code result.curl_exit result.stderr result.body)
  | None ->
      fail
        (Printf.sprintf "%s missing HTTP status (curl_exit=%d stderr=%s body=%s)" label
           result.curl_exit result.stderr result.body)

let extract_nickname_from_join_result result =
  (* Try "  Nickname: <nick>" line (first-join format) *)
  let prefix = "  Nickname: " in
  let lines = String.split_on_char '\n' result in
  let from_nickname_line =
    List.find_map
      (fun line ->
        if String.length line >= String.length prefix
           && String.sub line 0 (String.length prefix) = prefix
        then
          Some
            (String.sub line (String.length prefix)
               (String.length line - String.length prefix))
        else
          None)
      lines
  in
  match from_nickname_line with
  | Some nickname when nickname <> "" -> nickname
  | _ ->
      (* Handle "already in room" format: "... <nickname> already in room ..." *)
      let already_suffix = " already in room" in
      let tick_prefix = "\xe2\x9c\x85 " in (* UTF-8 for check mark emoji *)
      (match
        List.find_map
          (fun line ->
            let trimmed = String.trim line in
            if String.length trimmed > String.length tick_prefix + String.length already_suffix
               && String.sub trimmed 0 (String.length tick_prefix) = tick_prefix
            then
              let rest = String.sub trimmed (String.length tick_prefix)
                           (String.length trimmed - String.length tick_prefix) in
              match String.split_on_char ' ' rest with
              | nickname :: _ when nickname <> "" -> Some nickname
              | _ -> None
            else
              None)
          lines
      with
      | Some nickname -> nickname
      | None ->
          fail
            (Printf.sprintf "failed to extract nickname from join result:\n%s" result))

let with_server ?(host = "127.0.0.1") ?(enable_auth = true) f =
  let exe = find_main_eio_exe () in
  let port = match find_free_port () with Some p -> p | None -> Alcotest.skip () in
  let log_file = Filename.temp_file "operator-mcp-e2e-" ".log" in
  let base_path = Filename.temp_file "operator-mcp-base-" "" in
  (try Sys.remove base_path with _ -> ());
  Unix.mkdir base_path 0o755;
  let project_root = Masc_test_deps.find_project_root () in
  let config_dir = Filename.concat project_root "config" in
  let personas_dir = Filename.concat config_dir "personas" in
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor-root"));
  let supervisor_nickname =
    Masc_mcp.Coord.join config ~agent_name:"supervisor-root"
      ~capabilities:[ "supervisor"; "operator" ] ()
    |> extract_nickname_from_join_result
  in
  let planner_nickname =
    Masc_mcp.Coord.join config ~agent_name:"planner"
      ~capabilities:[ "planner"; "team-session" ] ()
    |> extract_nickname_from_join_result
  in
  let implementer_a_nickname =
    Masc_mcp.Coord.join config ~agent_name:"implementer-a"
      ~capabilities:[ "backend"; "team-session" ] ()
    |> extract_nickname_from_join_result
  in
  let implementer_b_nickname =
    Masc_mcp.Coord.join config ~agent_name:"implementer-b"
      ~capabilities:[ "docs"; "tests"; "team-session" ] ()
    |> extract_nickname_from_join_result
  in
  Mirage_crypto_rng_unix.use_default ();
  let supervisor_token, planner_token, implementer_a_token, implementer_b_token =
    if enable_auth then begin
      ignore (Masc_mcp.Auth.enable_auth config.base_path ~require_token:true ~agent_name:"test-supervisor");
      let supervisor_token =
        match
          Masc_mcp.Auth.create_token config.base_path ~agent_name:supervisor_nickname
            ~role:Masc_domain.Admin
        with
        | Ok (token, _cred) -> token
        | Error err ->
            fail
              (Printf.sprintf "failed to create supervisor token: %s"
                 (Masc_domain.masc_error_to_string err))
      in
      let create_worker_token agent_name =
        match
          Masc_mcp.Auth.create_token config.base_path ~agent_name
            ~role:Masc_domain.Worker
        with
        | Ok (token, _cred) -> token
        | Error err ->
            fail
              (Printf.sprintf "failed to create %s token: %s" agent_name
                 (Masc_domain.masc_error_to_string err))
      in
      ( supervisor_token,
        create_worker_token planner_nickname,
        create_worker_token implementer_a_nickname,
        create_worker_token implementer_b_nickname )
    end else
      ("", "", "", "")
  in
  let log_fd =
    Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
  in
  let env =
    merge_env_overrides
      [
        ("MASC_AUTONOMY_ENABLED", "0");
        ("GRAPHQL_API_KEY", "");
        ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
        ("MASC_HOST", host);
        ("MASC_POSTGRES_URL", "");
        ("DATABASE_URL", "");
        ("SUPABASE_DB_URL", "");
        ("SB_PG_URL", "");
        ("MASC_CONFIG_DIR", config_dir);
        ("MASC_PERSONAS_DIR", personas_dir);
        ("MASC_BOARD_BACKEND", "jsonl");
      ]
  in
  let argv =
    [|
      exe;
      "--host";
      host;
      "--port";
      string_of_int port;
      "--base-path";
      base_path;
    |]
  in
  let pid = Unix.create_process_env exe argv env Unix.stdin log_fd log_fd in
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
      f ~port ~supervisor_token ~planner_token ~implementer_a_token
        ~implementer_b_token ~supervisor_nickname ~planner_nickname
        ~implementer_a_nickname ~implementer_b_nickname)

let _test_operator_mcp_supervision_impl () =
  Alcotest.skip ()

let test_mcp_requires_auth_when_bound_non_loopback () =
  with_server ~host:"0.0.0.0" ~enable_auth:false
  @@ fun ~port ~supervisor_token:_ ~planner_token:_ ~implementer_a_token:_
            ~implementer_b_token:_ ~supervisor_nickname:_ ~planner_nickname:_
            ~implementer_a_nickname:_ ~implementer_b_nickname:_ ->
  let rec call_until_ready retries_left =
    let result =
      run_curl_json ~port ~path:"/mcp" ~session_id:"strict-remote"
        ~payload:(tools_list_payload ~id:1) ()
    in
    match (result.status, retries_left) with
    | Some 503, retries
      when retries > 0
           && contains_substr "Server is starting up, not ready yet" result.body ->
        Unix.sleepf 0.5;
        call_until_ready (retries - 1)
    | _ -> result
  in
  let result = call_until_ready 40 in
  Alcotest.(check (option int)) "returns unauthorized" (Some 401) result.status;
  check bool "strict auth message" true
    (contains_substr "requires room auth enabled with require_token=true"
       result.body)

let test_agent_json_route_served_on_canonical_path () =
  with_server ~enable_auth:false
  @@ fun ~port ~supervisor_token:_ ~planner_token:_ ~implementer_a_token:_
            ~implementer_b_token:_ ~supervisor_nickname:_ ~planner_nickname:_
            ~implementer_a_nickname:_ ~implementer_b_nickname:_ ->
  (* Retry up to 3 times to allow server_state initialization after /health readiness *)
  let rec fetch_agent_card retries =
    let result = run_curl_get ~port ~path:"/.well-known/agent.json" () in
    match result.status with
    | Some 200 ->
        let json =
          try Yojson.Safe.from_string result.body
          with Yojson.Json_error err ->
            fail
              (Printf.sprintf "agent.json invalid JSON: %s\nbody=%s" err result.body)
        in
        (match json |> U.member "name" |> U.to_string_option with
        | Some name -> (json, name)
        | None when retries > 0 ->
            Unix.sleepf 0.5;
            fetch_agent_card (retries - 1)
        | None ->
            fail
              (Printf.sprintf "agent.json name is null after retries\nbody=%s"
                 result.body))
    | _ when retries > 0 ->
        Unix.sleepf 0.5;
        fetch_agent_card (retries - 1)
    | _ ->
        require_http_ok "agent.json" result;
        fail "unreachable"
  in
  let (_json, name) = fetch_agent_card 3 in
  check string "agent card name present" "MASC-MCP" name

let () =
  run "operator_mcp_e2e"
    [
      ( "operator",
        [
          test_case "full mcp requires auth on non-loopback bind" `Slow
            test_mcp_requires_auth_when_bound_non_loopback;
          test_case "canonical agent discovery route" `Quick
            test_agent_json_route_served_on_canonical_path;
        ] );
    ]
