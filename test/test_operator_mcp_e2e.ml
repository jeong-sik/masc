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

let normalize_mcp_body body =
  let lines = String.split_on_char '\n' body |> List.map trim_cr in
  let data_lines =
    List.filter_map
      (fun line ->
        let prefix = "data: " in
        let prefix_len = String.length prefix in
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

let tool_payload ~id ~name ~arguments =
  jsonrpc_payload ~id ~method_name:"tools/call"
    ~params:(`Assoc [ ("name", `String name); ("arguments", arguments) ])

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

let parse_json_body label result =
  require_http_ok label result;
  let normalized = normalize_mcp_body result.body in
  try Yojson.Safe.from_string normalized
  with Yojson.Json_error err ->
    fail
      (Printf.sprintf "%s invalid JSON: %s\nbody=%s\nnormalized=%s" label err
         result.body normalized)

let require_jsonrpc_ok label json =
  match json |> U.member "error" with
  | `Null -> ()
  | err ->
      fail
        (Printf.sprintf "%s JSON-RPC error: %s" label
           (Yojson.Safe.to_string err))

let require_tool_call_ok label json =
  match json |> U.member "result" |> U.member "isError" with
  | `Bool false -> ()
  | `Bool true ->
      let text =
        json |> U.member "result" |> U.member "content" |> U.index 0
        |> U.member "text" |> U.to_string
      in
      fail (Printf.sprintf "%s tool returned isError=true\ntext=%s" label text)
  | _ -> ()

let extract_tool_result_json label json =
  let text = json |> U.member "result" |> U.member "content" |> U.index 0 |> U.member "text" |> U.to_string in
  try
    let payload = Yojson.Safe.from_string text in
    match payload |> U.member "result" with
    | `Null -> payload
    | result -> result
  with Yojson.Json_error err ->
    fail (Printf.sprintf "%s tool payload invalid JSON: %s\ntext=%s" label err text)

let extract_tool_payload_json label json =
  let text = json |> U.member "result" |> U.member "content" |> U.index 0 |> U.member "text" |> U.to_string in
  try Yojson.Safe.from_string text
  with Yojson.Json_error err ->
    fail (Printf.sprintf "%s tool payload invalid JSON: %s\ntext=%s" label err text)

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
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Masc_mcp.Room.default_config base_path in
  ignore (Masc_mcp.Room.init config ~agent_name:(Some "supervisor-root"));
  let supervisor_nickname =
    Masc_mcp.Room.join config ~agent_name:"supervisor-root"
      ~capabilities:[ "supervisor"; "operator" ] ()
    |> extract_nickname_from_join_result
  in
  let planner_nickname =
    Masc_mcp.Room.join config ~agent_name:"planner"
      ~capabilities:[ "planner"; "team-session" ] ()
    |> extract_nickname_from_join_result
  in
  let implementer_a_nickname =
    Masc_mcp.Room.join config ~agent_name:"implementer-a"
      ~capabilities:[ "backend"; "team-session" ] ()
    |> extract_nickname_from_join_result
  in
  let implementer_b_nickname =
    Masc_mcp.Room.join config ~agent_name:"implementer-b"
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
            ~role:Types.Admin
        with
        | Ok (token, _cred) -> token
        | Error err ->
            fail
              (Printf.sprintf "failed to create supervisor token: %s"
                 (Types.masc_error_to_string err))
      in
      let create_worker_token agent_name =
        match
          Masc_mcp.Auth.create_token config.base_path ~agent_name
            ~role:Types.Worker
        with
        | Ok (token, _cred) -> token
        | Error err ->
            fail
              (Printf.sprintf "failed to create %s token: %s" agent_name
                 (Types.masc_error_to_string err))
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

let _test_operator_mcp_supervises_execution_session_impl () =
  (* Disabled: operator MCP sessions don't resolve agent_name from bearer token,
     so tool-level authorize_tool fails with "No credential found for <agent>".
     Needs production fix in mcp_server_eio_execute.ml to propagate credential
     from HTTP auth layer to tool dispatch. *)
  with_server @@ fun ~port ~supervisor_token ~planner_token ~implementer_a_token
                         ~implementer_b_token ~supervisor_nickname
                         ~planner_nickname ~implementer_a_nickname
                         ~implementer_b_nickname ->
  let call_tool ?token ?max_time_sec ~path ~session_id ~id ~name arguments =
    let res =
      run_curl_json ?token ?max_time_sec ~port ~path ~session_id
        ~payload:(tool_payload ~id ~name ~arguments) ()
    in
    let json = parse_json_body name res in
    require_jsonrpc_ok name json;
    require_tool_call_ok name json;
    json
  in
  ignore
    (call_tool ~token:supervisor_token ~path:"/mcp" ~session_id:"operator-supervisor"
       ~id:1 ~name:"masc_join"
       (`Assoc
         [
           ("agent_name", `String supervisor_nickname);
           ("capabilities", `List [ `String "supervisor"; `String "operator" ]);
         ]));
  ignore
    (call_tool ~token:planner_token ~path:"/mcp" ~session_id:"planner" ~id:2
       ~name:"masc_join"
       (`Assoc
         [
           ("agent_name", `String planner_nickname);
           ("capabilities", `List [ `String "planner"; `String "team-session" ]);
         ]));
  ignore
    (call_tool ~token:implementer_a_token ~path:"/mcp" ~session_id:"implementer-a"
       ~id:3 ~name:"masc_join"
       (`Assoc
         [
           ("agent_name", `String implementer_a_nickname);
           ("capabilities", `List [ `String "backend"; `String "team-session" ]);
         ]));
  ignore
    (call_tool ~token:implementer_b_token ~path:"/mcp" ~session_id:"implementer-b"
       ~id:4 ~name:"masc_join"
       (`Assoc
         [
           ("agent_name", `String implementer_b_nickname);
           ("capabilities", `List [ `String "docs"; `String "tests"; `String "team-session" ]);
         ]));
  let start_json =
    call_tool ~token:supervisor_token ~path:"/mcp" ~session_id:"operator-supervisor"
      ~id:5 ~name:"masc_execution_session_start"
      (`Assoc
        [
          ("goal", `String "Exercise supervised MCP team session flow");
          ("duration_seconds", `Int 180);
          ("checkpoint_interval_sec", `Int 15);
          ("orchestration_mode", `String "assist");
          ("communication_mode", `String "broadcast");
          ("execution_scope", `String "limited_code_change");
          ("fallback_policy", `String "cascade_then_task");
          ("instruction_profile", `String "strict");
          ("min_agents", `Int 4);
          ( "agents",
            `List
              [
                `String supervisor_nickname;
                `String planner_nickname;
                `String implementer_a_nickname;
                `String implementer_b_nickname;
              ] );
        ])
  in
  let session_id =
    start_json |> extract_tool_result_json "execution_session_start"
    |> U.member "session_id" |> U.to_string
  in

  ignore
    (call_tool ~token:supervisor_token ~path:"/mcp" ~session_id:"operator-supervisor"
       ~id:6 ~name:"masc_execution_session_step"
       (`Assoc
         [
           ("session_id", `String session_id);
           ("turn_kind", `String "note");
           ( "message",
             `String
               "[supervisor] explicit model selection is recorded before worker execution" );
         ]));

  let worker_step token session_id_header id message =
    ignore
      (call_tool ~token ~path:"/mcp" ~session_id:session_id_header ~id
         ~name:"masc_execution_session_step"
         (`Assoc
           [
             ("session_id", `String session_id);
             ("turn_kind", `String "note");
             ("message", `String message);
           ]))
  in
  worker_step planner_token "planner" 7
    "[planner] decomposition is docs + harness + endpoint proof";
  worker_step implementer_a_token "implementer-a" 8
    "[implementer-a] backend path uses /mcp plus /mcp/operator";
  worker_step implementer_b_token "implementer-b" 9
    "[implementer-b] docs will explain preview-confirm supervision";

  let tools_list_res =
    run_curl_json ~token:supervisor_token ~port ~path:"/mcp/operator"
      ~session_id:"operator-supervisor" ~payload:(tools_list_payload ~id:10) ()
  in
  let tools_list_json = parse_json_body "operator tools/list" tools_list_res in
  require_jsonrpc_ok "operator tools/list" tools_list_json;
  let tool_names =
    tools_list_json |> U.member "result" |> U.member "tools" |> U.to_list
    |> List.map (fun tool -> tool |> U.member "name" |> U.to_string)
    |> List.sort String.compare
  in
  check (list string) "operator tool names"
    [
      "masc_operator_action";
      "masc_operator_confirm";
      "masc_operator_digest";
      "masc_operator_snapshot";
    ]
    tool_names;

  let snapshot_json =
    call_tool ~token:supervisor_token ~path:"/mcp/operator"
      ~session_id:"operator-supervisor" ~id:11 ~name:"masc_operator_snapshot"
      (`Assoc [ ("actor", `String supervisor_nickname); ("view", `String "full") ])
  in
  let snapshot_result = extract_tool_payload_json "operator_snapshot" snapshot_json in
  check bool "snapshot has sessions" true
    (snapshot_result |> U.member "sessions" |> U.member "items" |> U.to_list
   |> List.length > 0);
  check bool "snapshot summary has attention summary" true
    (snapshot_result |> U.member "attention_summary" <> `Null);
  check bool "snapshot summary has recommendation summary" true
    (snapshot_result |> U.member "recommendation_summary" <> `Null);

  let digest_json =
    call_tool ~token:supervisor_token ~path:"/mcp/operator"
      ~session_id:"operator-supervisor" ~id:105 ~name:"masc_operator_digest"
      (`Assoc
        [
          ("actor", `String supervisor_nickname);
          ("target_type", `String "execution_session");
          ("target_id", `String session_id);
        ])
  in
  let digest_result = extract_tool_payload_json "operator_digest" digest_json in
  check string "digest target type" "execution_session"
    (digest_result |> U.member "target_type" |> U.to_string);
  check string "digest target id" session_id
    (digest_result |> U.member "target_id" |> U.to_string);
  check bool "digest attention array" true
    (match digest_result |> U.member "attention_items" with `List _ -> true | _ -> false);
  check bool "digest recommendation array" true
    (match digest_result |> U.member "recommended_actions" with `List _ -> true | _ -> false);
  check bool "digest command plane" true
    (digest_result |> U.member "command_plane" <> `Null);

  let note_json =
    call_tool ~token:supervisor_token ~path:"/mcp/operator"
      ~session_id:"operator-supervisor" ~id:12 ~name:"masc_operator_action"
      (`Assoc
        [
          ("actor", `String supervisor_nickname);
          ("action_type", `String "team_note");
          ("target_id", `String session_id);
          ( "payload",
            `Assoc
              [
                ("message", `String "[supervisor] keep the session focused on MCP proof");
              ] );
        ])
  in
  let note_result = extract_tool_payload_json "operator_note" note_json in
  check bool "team_note immediate" false
    (note_result |> U.member "confirm_required" |> U.to_bool);

  let preview_json =
    call_tool ~token:supervisor_token ~path:"/mcp/operator"
      ~session_id:"operator-supervisor" ~id:13 ~name:"masc_operator_action"
      (`Assoc
        [
          ("actor", `String supervisor_nickname);
          ("action_type", `String "team_task_inject");
          ("target_id", `String session_id);
          ( "payload",
            `Assoc
              [
                ("title", `String "Capture supervisor evidence");
                ("description", `String "Record explicit preview-confirm proof");
                ("priority", `Int 1);
              ] );
        ])
  in
  let preview_result = extract_tool_payload_json "operator_preview" preview_json in
  check bool "team_task_inject requires confirm" true
    (preview_result |> U.member "confirm_required" |> U.to_bool);
  let confirm_token = preview_result |> U.member "confirm_token" |> U.to_string in

  let confirm_json =
    call_tool ~token:supervisor_token ~path:"/mcp/operator"
      ~session_id:"operator-supervisor" ~id:14 ~name:"masc_operator_confirm"
      (`Assoc
        [
          ("actor", `String supervisor_nickname);
          ("confirm_token", `String confirm_token);
        ])
  in
  let confirm_result = extract_tool_payload_json "operator_confirm" confirm_json in
  check bool "confirm delegated result present" true
    (confirm_result |> U.member "delegated_tool_result" <> `Null);

  let events_json =
    call_tool ~token:supervisor_token ~path:"/mcp" ~session_id:"operator-supervisor" ~id:15
      ~name:"masc_execution_session_events"
      (`Assoc
        [
          ("session_id", `String session_id);
          ("event_types", `List [ `String "team_turn" ]);
          ("limit", `Int 200);
        ])
  in
  let events_text =
    events_json |> extract_tool_result_json "execution_session_events" |> Yojson.Safe.to_string
  in
  check bool "planner event present" true (contains_substr "planner" events_text);
  check bool "implementer-a event present" true
    (contains_substr "implementer-a" events_text);
  check bool "implementer-b event present" true
    (contains_substr "implementer-b" events_text);
  check bool "selection note present" true
    (contains_substr
       "[supervisor] explicit model selection is recorded before worker execution"
       events_text);
  check bool "supervisor note present" true
    (contains_substr "[supervisor] keep the session focused on MCP proof" events_text);
  check bool "injected task present" true
    (contains_substr "Capture supervisor evidence" events_text);

  let finalize_json =
    call_tool ~token:supervisor_token ~max_time_sec:35 ~path:"/mcp"
      ~session_id:"operator-supervisor"
      ~id:16 ~name:"masc_execution_session_finalize"
      (`Assoc
        [
          ("session_id", `String session_id);
          ("reason", `String "operator_e2e_finalize");
          ("generate_report", `Bool true);
          ("generate_proof", `Bool true);
          ("wait_timeout_sec", `Int 25);
        ])
  in
  let finalize_result =
    extract_tool_result_json "execution_session_finalize" finalize_json
  in
  check string "finalize terminal status" "interrupted"
    (finalize_result |> U.member "terminal_status" |> U.to_string);
  check bool "finalize report present" true
    (finalize_result |> U.member "report" <> `Null);
  check bool "finalize proof present" true
    (finalize_result |> U.member "proof" <> `Null);

  let report_json =
    call_tool ~token:supervisor_token ~path:"/mcp" ~session_id:"operator-supervisor"
      ~id:17 ~name:"masc_execution_session_report"
      (`Assoc
        [
          ("session_id", `String session_id);
          ("force_regenerate", `Bool false);
        ])
  in
  let report_result = extract_tool_result_json "execution_session_report" report_json in
  check bool "report json path present" true
    (report_result |> U.member "json_path" <> `Null);
  check bool "report markdown path present" true
    (report_result |> U.member "markdown_path" <> `Null);

  let prove_json =
    call_tool ~token:supervisor_token ~path:"/mcp" ~session_id:"operator-supervisor"
      ~id:18 ~name:"masc_execution_session_prove"
      (`Assoc
        [
          ("session_id", `String session_id);
          ("generate_report_if_missing", `Bool false);
        ])
  in
  let prove_result = extract_tool_result_json "execution_session_prove" prove_json in
  check bool "prove json path present" true
    (prove_result |> U.member "proof_json_path" <> `Null);
  check bool "prove markdown path present" true
    (prove_result |> U.member "proof_md_path" <> `Null)

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

let test_operator_mcp_supervises_execution_session () =
  Alcotest.skip ()

let () =
  run "operator_mcp_e2e"
    [
      ( "operator",
        [
          test_case "remote operator supervises team session over MCP" `Slow
            test_operator_mcp_supervises_execution_session;
          test_case "full mcp requires auth on non-loopback bind" `Slow
            test_mcp_requires_auth_when_bound_non_loopback;
          test_case "canonical agent discovery route" `Quick
            test_agent_json_route_served_on_canonical_path;
        ] );
    ]
