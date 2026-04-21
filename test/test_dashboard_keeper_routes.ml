open Alcotest
module Routes = Masc_mcp.Server_routes_http_routes_dashboard
module Keeper_api = Masc_mcp.Server_dashboard_http_keeper_api

type http_result =
  { status : int option
  ; body : string
  ; curl_exit : int
  ; stderr : string
  }

let read_all ic =
  let buf = Buffer.create 1024 in
  (try
     while true do
       Buffer.add_channel buf ic 4096
     done
   with
   | End_of_file -> ());
  Buffer.contents buf
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len)
;;

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)
;;

let rec mkdir_p path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let trim_cr s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s
;;

let parse_status header_raw =
  let lines = String.split_on_char '\n' header_raw |> List.map trim_cr in
  let rec find_http = function
    | [] -> None
    | line :: rest ->
      if String.length line >= 5 && String.sub line 0 5 = "HTTP/"
      then (
        match String.split_on_char ' ' line with
        | _proto :: code :: _ ->
          (try Some (int_of_string code) with
           | _ -> None)
        | _ -> None)
      else find_http rest
  in
  find_http lines
;;

let contains_substr needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h
    then false
    else if String.sub haystack i n = needle
    then true
    else loop (i + 1)
  in
  n = 0 || loop 0
;;

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
      [ "./bin/main_eio.exe"
      ; "../bin/main_eio.exe"
      ; "../../bin/main_eio.exe"
      ; "../../../bin/main_eio.exe"
      ; "../../../../bin/main_eio.exe"
      ]
      @ build_candidates
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None ->
    fail
      "main_eio executable not found. Set MASC_MAIN_EIO_EXE or build with `dune build \
       bin/main_eio.exe`."
;;

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
       Unix.setsockopt socket Unix.SO_REUSEADDR true;
       match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
       | () ->
         (match Unix.getsockname socket with
         | Unix.ADDR_INET (_, port) -> Some port
         | _ -> fail "unexpected socket address")
       | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) -> None)
;;

let mock_openai_text_response ?(id = "chatcmpl-dashboard-routes") text =
  Printf.sprintf
    {|{"id":"%s","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}|}
    id text
;;

let wait_for_tcp_listener ~port ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close socket)
      (fun () ->
         match Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) with
         | () -> true
         | exception Unix.Unix_error _ ->
           if Unix.gettimeofday () > deadline
           then false
           else (
             Unix.sleepf 0.05;
             loop ()))
  in
  loop ()
;;

let with_mock_model f =
  let port =
    match find_free_port () with
    | Some port -> port
    | None -> Alcotest.skip ()
  in
  let rec wait_child_exit ~pid ~deadline =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if Unix.gettimeofday () > deadline
      then false
      else (
        Unix.sleepf 0.05;
        wait_child_exit ~pid ~deadline)
    | _pid, _status -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  let response_body = mock_openai_text_response "pong" in
  match Unix.fork () with
  | 0 ->
    Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
    let server = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.setsockopt server Unix.SO_REUSEADDR true;
    Unix.bind server (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
    Unix.listen server 16;
    let response =
      Printf.sprintf
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
        (String.length response_body)
        response_body
    in
    let rec serve () =
      let client, _addr = Unix.accept server in
      Fun.protect
        ~finally:(fun () -> Unix.close client)
        (fun () ->
           let buffer = Bytes.create 4096 in
           (try ignore (Unix.read client buffer 0 (Bytes.length buffer)) with
            | Unix.Unix_error _ -> ());
           try ignore (Unix.write_substring client response 0 (String.length response)) with
           | Unix.Unix_error _ -> ());
      serve ()
    in
    serve ()
  | pid ->
    let cleanup () =
      (try Unix.kill pid Sys.sigterm with
       | _ -> ());
      ignore (wait_child_exit ~pid ~deadline:(Unix.gettimeofday () +. 1.0))
    in
    if not (wait_for_tcp_listener ~port ~timeout_s:2.0)
    then (
      cleanup ();
      fail (Printf.sprintf "mock model server failed to listen on port %d" port));
    Fun.protect
      ~finally:cleanup
      (fun () ->
         f (Printf.sprintf "custom:mock@http://127.0.0.1:%d/v1" port))
;;

let wait_for_health ~port ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if Unix.gettimeofday () > deadline
    then false
    else (
      let res =
        let header_file = Filename.temp_file "dashboard-keeper-health-" ".hdr" in
        let body_file = Filename.temp_file "dashboard-keeper-health-" ".body" in
        let url = Printf.sprintf "http://127.0.0.1:%d/health" port in
        let args =
          [| "curl"
           ; "-sS"
           ; "--http1.1"
           ; "--max-time"
           ; "1"
           ; "-X"
           ; "GET"
           ; "-o"
           ; body_file
           ; "-D"
           ; header_file
           ; url
          |]
        in
        let ic, oc, ec = Unix.open_process_args_full "curl" args (Unix.environment ()) in
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
        (try Sys.remove header_file with
         | _ -> ());
        (try Sys.remove body_file with
         | _ -> ());
        { status; body; curl_exit; stderr }
      in
      match res.status with
      | Some 200 when contains_substr "\"state_ready\":true" res.body -> true
      | _ ->
        Unix.sleepf 0.1;
        loop ())
  in
  loop ()
;;

let wait_pid_exit ~pid ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if Unix.gettimeofday () > deadline
      then false
      else (
        Unix.sleepf 0.05;
        loop ())
    | _pid, _status -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  loop ()
;;

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
;;

let has_env_override key overrides =
  List.exists (fun (name, _value) -> String.equal name key) overrides
;;

let repo_config_path name =
  Filename.concat (Filename.concat (Masc_test_deps.find_project_root ()) "config") name
;;

let with_temp_config_root cascade_json f =
  let root = Filename.temp_file "dashboard-keeper-config-" "" in
  (try Sys.remove root with
   | _ -> ());
  Unix.mkdir root 0o755;
  let cleanup () = rm_rf root in
  Fun.protect
    ~finally:cleanup
    (fun () ->
       mkdir_p (Filename.concat root "personas");
       mkdir_p (Filename.concat root "keepers");
       mkdir_p (Filename.concat root "prompts");
       write_file (Filename.concat root "cascade.json") cascade_json;
       write_file
         (Filename.concat root "tool_policy.toml")
         (read_file (repo_config_path "tool_policy.toml"));
       f root)
;;

let with_config_dir config_root f =
  let prev = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
       (match prev with
        | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
        | None -> Unix.putenv "MASC_CONFIG_DIR" "");
       Masc_mcp.Config_dir_resolver.reset ())
    (fun () ->
       Unix.putenv "MASC_CONFIG_DIR" config_root;
       Masc_mcp.Config_dir_resolver.reset ();
       f ())
;;

let run_curl_post ?body ?token ~port ~path () =
  let header_file = Filename.temp_file "dashboard-keeper-post-" ".hdr" in
  let body_file = Filename.temp_file "dashboard-keeper-post-" ".body" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let base_args =
    [ "curl"
    ; "-sS"
    ; "--http1.1"
    ; "--max-time"
    ; "3"
    ; "-X"
    ; "POST"
    ; "-o"
    ; body_file
    ; "-D"
    ; header_file
    ]
  in
  let data_file =
    match body with
    | None -> None
    | Some payload ->
      let path = Filename.temp_file "dashboard-keeper-post-" ".json" in
      write_file path payload;
      Some path
  in
  let args =
    let args =
      match data_file with
      | Some payload_path ->
        base_args
        @ [ "-H"; "Content-Type: application/json"; "--data-binary"; "@" ^ payload_path ]
      | None -> base_args
    in
    let args =
      match token with
      | Some raw_token ->
        args @ [ "-H"; Printf.sprintf "Authorization: Bearer %s" raw_token ]
      | None -> args
    in
    Array.of_list (args @ [ url ])
  in
  let ic, oc, ec = Unix.open_process_args_full "curl" args (Unix.environment ()) in
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
  (try Sys.remove header_file with
   | _ -> ());
  (try Sys.remove body_file with
   | _ -> ());
  Option.iter
    (fun path ->
       try Sys.remove path with
       | _ -> ())
    data_file;
  { status; body; curl_exit; stderr }
;;

let run_curl_get ?token ~port ~path () =
  let header_file = Filename.temp_file "dashboard-keeper-get-" ".hdr" in
  let body_file = Filename.temp_file "dashboard-keeper-get-" ".body" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let base_args =
    [ "curl"
    ; "-sS"
    ; "--http1.1"
    ; "--max-time"
    ; "3"
    ; "-X"
    ; "GET"
    ; "-o"
    ; body_file
    ; "-D"
    ; header_file
    ]
  in
  let args =
    let args =
      match token with
      | Some raw_token ->
          base_args @ [ "-H"; Printf.sprintf "Authorization: Bearer %s" raw_token ]
      | None -> base_args
    in
    Array.of_list (args @ [ url ])
  in
  let ic, oc, ec = Unix.open_process_args_full "curl" args (Unix.environment ()) in
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
  (try Sys.remove header_file with
   | _ -> ());
  (try Sys.remove body_file with
   | _ -> ());
  { status; body; curl_exit; stderr }
;;

let execution_keeper_paused body keeper_name =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string body in
  let keepers = json |> member "keepers" |> to_list in
  match
    List.find_opt
      (fun row -> row |> member "name" |> to_string = keeper_name)
      keepers
  with
  | Some row -> (
      match row |> member "paused" with
      | `Bool value -> value
      | `Null -> false
      | _ -> false)
  | None -> fail ("keeper missing from execution payload: " ^ keeper_name)
;;

let profile_names body =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string body in
  match json |> member "profiles" with
  | `List items ->
      List.filter_map
        (function
          | `String value -> Some value
          | _ -> None)
        items
  | _ -> []
;;

let make_keeper_meta_json ?(name = "route-shadow-demo") () =
  match
    Masc_mcp.Keeper_types.meta_of_json
      (`Assoc
          [ "name", `String name
          ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
          ; "trace_id", `String ("trace-" ^ name ^ "-seed")
          ; "goal", `String "Route shadow regression fixture"
          ; "cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name
          ; "updated_at", `String "2026-04-04T00:00:00Z"
          ; "paused", `Bool true
          ])
  with
  | Ok meta -> Masc_mcp.Keeper_types.meta_to_json meta |> Yojson.Safe.pretty_to_string
  | Error err -> fail ("keeper meta fixture parse failed: " ^ err)
;;

let seed_auth_and_keeper ~base_path ~keeper_name =
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "bootstrap-admin"));
  Fs_compat.mkdir_p (Masc_mcp.Keeper_types.keeper_dir config);
  write_file
    (Masc_mcp.Keeper_types.keeper_meta_path config keeper_name)
    (make_keeper_meta_json ~name:keeper_name ());
  ignore
    (Masc_mcp.Auth.enable_auth
       base_path
       ~require_token:true
       ~agent_name:"bootstrap-admin");
  let admin_token =
    match
      Masc_mcp.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Types.Admin
    with
    | Ok (token, _cred) -> token
    | Error err -> fail (Types.masc_error_to_string err)
  in
  config, admin_token
;;

let with_seeded_server ?(env_overrides = []) f =
  let run_with_env_overrides env_overrides =
    let exe = find_main_eio_exe () in
    let port =
      match find_free_port () with
      | Some p -> p
      | None -> Alcotest.skip ()
    in
    let log_file = Filename.temp_file "dashboard-keeper-routes-" ".log" in
    let base_path = Filename.temp_file "dashboard-keeper-base-" "" in
    let keeper_name = "route-shadow-demo" in
    (try Sys.remove base_path with
     | _ -> ());
    Unix.mkdir base_path 0o755;
    let config, admin_token = seed_auth_and_keeper ~base_path ~keeper_name in
    let log_fd =
      Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
    in
    let env =
      merge_env_overrides
        ([ "MASC_AUTONOMY_ENABLED", "0"
         ; "GRAPHQL_API_KEY", ""
         ; "GRAPHQL_URL", "http://127.0.0.1:9/graphql"
         ; "MASC_BASE_PATH", base_path
         ; "MASC_POSTGRES_URL", ""
         ; "DATABASE_URL", ""
         ; "SUPABASE_DB_URL", ""
         ; "SB_PG_URL", ""
         ; "MASC_BOARD_BACKEND", "jsonl"
         ]
         @ env_overrides)
    in
    let argv =
      [| exe
       ; "--host"
       ; "127.0.0.1"
       ; "--port"
       ; string_of_int port
       ; "--base-path"
       ; base_path
      |]
    in
    let pid = Unix.create_process_env exe argv env Unix.stdin log_fd log_fd in
    Unix.close log_fd;
    let cleanup () =
      (try Unix.kill pid Sys.sigterm with
       | _ -> ());
      if not (wait_pid_exit ~pid ~timeout_s:2.0)
      then (
        try Unix.kill pid Sys.sigkill with
        | _ -> ());
      ignore (wait_pid_exit ~pid ~timeout_s:1.0);
      rm_rf log_file;
      rm_rf base_path
    in
    if not (wait_for_health ~port ~timeout_s:20.0)
    then (
      let logs = read_file log_file in
      cleanup ();
      fail (Printf.sprintf "server failed to become ready on port %d\n%s" port logs));
    Fun.protect ~finally:cleanup (fun () -> f ~port ~config ~admin_token ~keeper_name)
  in
  if has_env_override "MASC_CONFIG_DIR" env_overrides
  then run_with_env_overrides env_overrides
  else
    with_mock_model @@ fun valid_model ->
    with_temp_config_root
      (Printf.sprintf
         {|{"default_models":["%s"],"keeper_unified_models":["%s"]}|}
         valid_model
         valid_model)
    @@ fun config_root ->
    run_with_env_overrides (("MASC_CONFIG_DIR", config_root) :: env_overrides)
;;

let check_route path expected =
  let actual = Keeper_api.classify_keeper_post_route path in
  if actual <> expected
  then
    failf
      "expected %s for %s"
      (match expected with
       | Keeper_api.Keeper_post_tools -> "tools"
       | Keeper_api.Keeper_post_config -> "config"
       | Keeper_api.Keeper_post_boot -> "boot"
       | Keeper_api.Keeper_post_shutdown -> "shutdown"
       | Keeper_api.Keeper_post_reset -> "reset"
       | Keeper_api.Keeper_post_clear -> "clear"
       | Keeper_api.Keeper_post_checkpoints -> "checkpoints"
       | Keeper_api.Keeper_post_directive -> "directive"
       | Keeper_api.Keeper_post_unknown -> "unknown")
      path
;;

let test_keeper_post_route_classification () =
  check_route "/api/v1/keepers/sangsu/tools" Keeper_api.Keeper_post_tools;
  check_route "/api/v1/keepers/sangsu/config" Keeper_api.Keeper_post_config;
  check_route "/api/v1/keepers/sangsu/boot" Keeper_api.Keeper_post_boot;
  check_route "/api/v1/keepers/sangsu/shutdown" Keeper_api.Keeper_post_shutdown;
  check_route "/api/v1/keepers/sangsu/reset" Keeper_api.Keeper_post_reset;
  check_route "/api/v1/keepers/sangsu/clear" Keeper_api.Keeper_post_clear;
  check_route "/api/v1/keepers/sangsu/checkpoints" Keeper_api.Keeper_post_checkpoints;
  check_route "/api/v1/keepers/sangsu/directive" Keeper_api.Keeper_post_directive;
  check_route "/api/v1/keepers/sangsu" Keeper_api.Keeper_post_unknown;
  check_route "/api/v1/keepers//boot" Keeper_api.Keeper_post_unknown
;;

let require_status label expected result =
  match result.status with
  | Some code -> check int label expected code
  | None ->
    fail
      (Printf.sprintf
         "%s missing HTTP status (curl_exit=%d stderr=%s body=%s)"
         label
         result.curl_exit
         result.stderr
         result.body)
;;

let test_keeper_lifecycle_routes_do_not_fall_through_to_generic_404 () =
  with_seeded_server
  @@ fun ~port ~config ~admin_token ~keeper_name ->
  let boot_path = Printf.sprintf "/api/v1/keepers/%s/boot" keeper_name in
  let shutdown_path = Printf.sprintf "/api/v1/keepers/%s/shutdown" keeper_name in
  let clear_path = Printf.sprintf "/api/v1/keepers/%s/clear" keeper_name in
  let boot_result =
    run_curl_post ~body:"{}" ~token:admin_token ~port ~path:boot_path ()
  in
  require_status "boot route returns 200" 200 boot_result;
  check
    bool
    "boot route is not generic 404"
    false
    (contains_substr {|{"error":"not found"}|} boot_result.body);
  check
    bool
    "boot route reaches lifecycle handler"
    true
    (contains_substr {|"action":"boot"|} boot_result.body);
  (match Masc_mcp.Keeper_types.read_meta config keeper_name with
   | Ok (Some meta) ->
       check bool "boot resumes paused keeper meta" false meta.paused
   | Ok None -> fail "keeper meta missing after boot route"
   | Error err -> fail ("failed to read keeper meta after boot route: " ^ err));
  let execution_after_boot =
    run_curl_get ~port ~path:"/api/v1/dashboard/execution" ()
  in
  require_status "execution GET returns 200 after boot" 200 execution_after_boot;
  check bool "execution reflects resumed keeper after boot" false
    (execution_keeper_paused execution_after_boot.body keeper_name);
  let shutdown_result =
    run_curl_post ~body:"{}" ~token:admin_token ~port ~path:shutdown_path ()
  in
  require_status "shutdown route returns 200" 200 shutdown_result;
  check
    bool
    "shutdown route is not generic 404"
    false
    (contains_substr {|{"error":"not found"}|} shutdown_result.body);
  check
    bool
    "shutdown route reaches lifecycle handler"
    true
    (contains_substr {|"action":"shutdown"|} shutdown_result.body);
  (match Masc_mcp.Keeper_types.read_meta config keeper_name with
   | Ok (Some meta) ->
       let updated_meta =
         {
           meta with
           continuity_summary = "stale continuity snapshot";
           updated_at = Masc_mcp.Keeper_types.now_iso ();
           runtime =
             {
               meta.runtime with
               last_continuity_update_ts = 1234.0;
             };
         }
       in
       (match Masc_mcp.Keeper_types.write_meta ~force:true config updated_meta with
        | Ok () -> ()
        | Error err -> fail ("failed to seed continuity summary: " ^ err))
   | Ok None -> fail "keeper meta missing before clear route"
   | Error err -> fail ("failed to read keeper meta before clear: " ^ err));
  let clear_result =
    run_curl_post
      ~body:{|{"reason":"reset stale continuity","preserve_system_prompt":true}|}
      ~token:admin_token
      ~port
      ~path:clear_path
      ()
  in
  require_status "clear route returns 200" 200 clear_result;
  check
    bool
    "clear route is not generic 404"
    false
    (contains_substr {|{"error":"not found"}|} clear_result.body);
  check
    bool
    "clear route reaches lifecycle handler"
    true
    (contains_substr {|"action":"clear"|} clear_result.body);
  check
    bool
    "clear route reports continuity cleanup"
    true
    (contains_substr {|"continuity_cleared":true|} clear_result.body);
  (match Masc_mcp.Keeper_types.read_meta config keeper_name with
   | Ok (Some meta) ->
       check string "clear resets continuity summary" "" meta.continuity_summary;
       check (float 0.0001) "clear resets continuity freshness" 0.0
         meta.runtime.last_continuity_update_ts
   | Ok None -> fail "keeper meta missing after clear route"
   | Error err -> fail ("failed to read keeper meta after clear: " ^ err));
  match Masc_mcp.Keeper_types.read_meta config keeper_name with
  | Ok (Some meta) -> check bool "shutdown persists paused keeper meta" true meta.paused
  | Ok None -> fail "keeper meta missing after shutdown route"
  | Error err -> fail ("failed to read keeper meta after shutdown: " ^ err)
;;

let test_keeper_directive_resume_updates_paused_meta () =
  with_seeded_server
  @@ fun ~port ~config ~admin_token ~keeper_name ->
  let directive_path =
    Printf.sprintf "/api/v1/keepers/%s/directive" keeper_name
  in
  let resume_result =
    run_curl_post
      ~body:{|{"action":"resume"}|}
      ~token:admin_token
      ~port
      ~path:directive_path
      ()
  in
  require_status "directive route returns 200" 200 resume_result;
  check
    bool
    "directive route reaches lifecycle handler"
    true
    (contains_substr {|"action":"resume"|} resume_result.body);
  let execution_after_resume =
    run_curl_get ~port ~path:"/api/v1/dashboard/execution" ()
  in
  require_status "execution GET returns 200 after directive" 200 execution_after_resume;
  check bool "execution reflects resumed keeper after directive" false
    (execution_keeper_paused execution_after_resume.body keeper_name);
  match Masc_mcp.Keeper_types.read_meta config keeper_name with
  | Ok (Some meta) ->
      check bool "directive resume clears paused keeper meta" false meta.paused
  | Ok None -> fail "keeper meta missing after directive resume"
  | Error err ->
      fail ("failed to read keeper meta after directive resume: " ^ err)
;;

let test_available_cascade_profiles_filter_invalid_catalog_entries () =
  with_mock_model @@ fun valid_model ->
  with_temp_config_root
    (Printf.sprintf
       {|
      {
        "default_models": ["%s"],
        "good_models": ["%s"],
        "broken_models": ["__nonexistent_provider_sentinel__:fake-model"]
      }
    |}
       valid_model
       valid_model)
  @@ fun config_root ->
  with_config_dir config_root @@ fun () ->
  check
    (list string)
    "assignable cascades exclude invalid presets"
    [ "default"; "good" ]
    (Routes.available_cascade_profiles ());
  let invalid = Routes.invalid_cascade_profiles () in
  check bool "invalid preset is surfaced separately" true
    (List.mem_assoc "broken" invalid)
;;

let test_keeper_cascade_routes_filter_invalid_catalog_entries () =
  with_mock_model @@ fun valid_model ->
  with_temp_config_root
    (Printf.sprintf
       {|
      {
        "default_models": ["%s"],
        "good_models": ["%s"],
        "broken_models": ["__nonexistent_provider_sentinel__:fake-model"]
      }
    |}
       valid_model
       valid_model)
  @@ fun config_root ->
  with_seeded_server
    ~env_overrides:[ "MASC_CONFIG_DIR", config_root ]
  @@ fun ~port ~config:_ ~admin_token ~keeper_name ->
  let list_result =
    run_curl_get ~port ~path:"/api/v1/keeper/cascades" ()
  in
  require_status "keeper cascades GET returns 200" 200 list_result;
  let profiles = profile_names list_result.body in
  check bool "valid profile remains assignable" true (List.mem "good" profiles);
  check bool "invalid profile omitted from assignable list" false
    (List.mem "broken" profiles);
  let assign_invalid_result =
    run_curl_post
      ~body:
        (Printf.sprintf
           {|{"keeper":"%s","cascade_name":"broken"}|}
           keeper_name)
      ~token:admin_token
      ~port
      ~path:"/api/v1/keeper/cascade"
      ()
  in
  require_status "invalid cascade assignment returns 409" 409 assign_invalid_result;
  check bool "invalid cascade rejection explains config error" true
    (contains_substr "invalid in active cascade.json" assign_invalid_result.body)
;;

let test_merge_keeper_trace_lines_includes_internal_history () =
  let base_path = Filename.temp_file "dashboard-keeper-trajectory-" "" in
  (try Sys.remove base_path with
   | _ -> ());
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "bootstrap-admin"));
  let trace_id = "trace-route-shadow-demo-seed" in
  let internal_history_path =
    Masc_mcp.Keeper_types.keeper_internal_history_path config trace_id
  in
  Fs_compat.mkdir_p (Filename.dirname internal_history_path);
  write_file
    internal_history_path
    (String.concat
       "\n"
       [ {|{"timestamp":1000.0,"ts_unix":1000.0,"source":"internal_assistant","role":"assistant","content":"first internal thought"}|}
       ; {|{"timestamp":1001.0,"ts_unix":1001.0,"source":"internal_assistant","role":"assistant","content":"second internal thought"}|}
       ]
     ^ "\n");
  let trajectory_lines =
    [
      Masc_mcp.Trajectory.Tool_call
        {
          Masc_mcp.Trajectory.ts = 1002.0;
          ts_iso = "1970-01-01T00:16:42Z";
          turn = 3;
          round = 1;
          tool_name = "masc_tasks";
          args_json = "{}";
          gate_decision = Masc_mcp.Trajectory.Pass;
          result = Some {|{"ok":true}|};
          duration_ms = 12;
          error = None;
          cost_usd = 0.0;
        };
    ]
  in
  let merged =
    Keeper_api.merge_keeper_trace_lines ~config ~trace_id trajectory_lines
  in
  check int "merged entry count" 3 (List.length merged);
  (match List.nth merged 0 with
   | Masc_mcp.Trajectory.Thinking entry ->
     check string "first merged content" "first internal thought" entry.content
   | Masc_mcp.Trajectory.Tool_call _ ->
     fail "expected internal history entry first");
  (match List.nth merged 1 with
   | Masc_mcp.Trajectory.Thinking entry ->
     check string "second merged content" "second internal thought" entry.content
   | Masc_mcp.Trajectory.Tool_call _ ->
     fail "expected internal history entry second");
  (match List.nth merged 2 with
   | Masc_mcp.Trajectory.Tool_call entry ->
     check string "tool entry remains present" "masc_tasks" entry.tool_name
   | Masc_mcp.Trajectory.Thinking _ ->
     fail "expected tool entry last");
  let tool_only =
    List.filter
      (function
        | Masc_mcp.Trajectory.Tool_call _ -> true
        | Masc_mcp.Trajectory.Thinking _ -> false)
      merged
  in
  check int "thinking entries can still be filtered out" 1 (List.length tool_only))
;;

let () =
  run
    "dashboard_keeper_routes"
    [ ( "dashboard_keeper_routes"
      , [ test_case
            "classify keeper POST routes"
            `Quick
            test_keeper_post_route_classification
        ; test_case
            "lifecycle POST routes do not fall through to generic 404"
            `Slow
            test_keeper_lifecycle_routes_do_not_fall_through_to_generic_404
        ; test_case
            "directive resume updates paused meta"
            `Slow
            test_keeper_directive_resume_updates_paused_meta
        ; test_case
            "available cascade profiles filter invalid catalog entries"
            `Quick
            test_available_cascade_profiles_filter_invalid_catalog_entries
        ; test_case
            "keeper cascade routes filter invalid catalog entries"
            `Slow
            test_keeper_cascade_routes_filter_invalid_catalog_entries
        ; test_case
            "merge keeper trace lines includes internal history"
            `Quick
            test_merge_keeper_trace_lines_includes_internal_history
        ] )
    ]
;;
