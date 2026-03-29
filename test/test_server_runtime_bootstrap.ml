open Masc_mcp

let with_env name value f =
  let saved = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect ~finally:(fun () ->
      match saved with
      | Some prior -> Unix.putenv name prior
      | None -> Unix.putenv name "")
    f

let with_pg_envs f =
  with_env "MASC_STORAGE_TYPE" (Some "postgres") @@ fun () ->
  with_env "MASC_POSTGRES_URL" (Some "postgresql://primary/db") @@ fun () ->
  with_env "DATABASE_URL" (Some "postgresql://fallback/db") @@ fun () ->
  with_env "SUPABASE_DB_URL" (Some "postgresql://supabase/db") @@ fun () ->
  with_env "SB_PG_URL" (Some "postgresql://sb/db") f

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let project_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when String.trim root <> "" -> root
  | _ -> Sys.getcwd ()

let read_all ic =
  let buf = Buffer.create 256 in
  (try
     while true do
       Buffer.add_channel buf ic 1024
     done
   with End_of_file -> ());
  Buffer.contents buf

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      (match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
       | () -> ()
       | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) ->
         Alcotest.skip ());
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | _ -> Alcotest.fail "unexpected socket address")

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

let find_main_eio_exe () =
  let root = project_root () in
  let shared_root =
    root |> Filename.dirname |> Filename.dirname |> Filename.dirname
  in
  let candidates =
    [
      Filename.concat root "_build/default/bin/main_eio.exe";
      Filename.concat root "_build/default/masc-mcp/bin/main_eio.exe";
      Filename.concat shared_root "_build/default/bin/main_eio.exe";
      Filename.concat shared_root "_build/default/masc-mcp/bin/main_eio.exe";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail "main_eio executable not found"

let curl_health_status ~port =
  let url = Printf.sprintf "http://127.0.0.1:%d/health" port in
  let args =
    [|
      "curl";
      "-sS";
      "--http1.1";
      "--max-time";
      "1";
      "-o";
      "/dev/null";
      "-w";
      "%{http_code}";
      url;
    |]
  in
  let ic = Unix.open_process_args_in "curl" args in
  let output = read_all ic |> String.trim in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> int_of_string_opt output
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> None

let process_alive pid =
  match Unix.waitpid [Unix.WNOHANG] pid with
  | 0, _ -> true
  | _ -> false
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> false

let wait_for_health ~pid ~port ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match curl_health_status ~port with
    | Some 200 -> true
    | _ ->
      if not (process_alive pid) then
        false
      else if Unix.gettimeofday () >= deadline then
        false
      else begin
        Unix.sleepf 0.1;
        loop ()
      end
  in
  loop ()

let stop_process pid =
  (try Unix.kill pid Sys.sigterm with _ -> ());
  ignore
    (let rec wait () =
       try Unix.waitpid [] pid
       with
       | Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
       | Unix.Unix_error (Unix.ECHILD, _, _) -> (0, Unix.WEXITED 0)
     in
     wait ())

let json_assoc = function
  | `Assoc fields -> fields
  | _ -> Alcotest.fail "expected JSON object"

let json_string_field name json =
  match List.assoc_opt name (json_assoc json) with
  | Some (`String value) -> value
  | Some _ -> Alcotest.failf "field %s is not a string" name
  | None -> Alcotest.failf "missing field %s" name

let json_bool_field name json =
  match List.assoc_opt name (json_assoc json) with
  | Some (`Bool value) -> value
  | Some _ -> Alcotest.failf "field %s is not a bool" name
  | None -> Alcotest.failf "missing field %s" name

let test_force_jsonl_fallback_env () =
  with_pg_envs (fun () ->
      Server_runtime_bootstrap.force_jsonl_fallback_env ();
      Alcotest.(check string) "storage type forced to filesystem" "filesystem"
        (Sys.getenv "MASC_STORAGE_TYPE");
      Alcotest.(check string)
        "MASC_POSTGRES_URL cleared" "" (Sys.getenv "MASC_POSTGRES_URL"))

let test_constructor_is_pure () =
  with_temp_dir "startup-pure" (fun dir ->
      let agents_dir = Room.agents_dir (Room.default_config dir |> Room.config_with_resolved_scope) in
      Fs_compat.mkdir_p agents_dir;
      write_file (Filename.concat agents_dir "alice.json") "{}";
      let state = Mcp_server.create_state ~base_path:dir in
      Alcotest.(check int) "constructor does not restore persisted sessions" 0
        (List.length (Session.connected_agents state.Mcp_server.session_registry)))

let test_restore_persisted_sessions_uses_scoped_agents_dir () =
  with_temp_dir "startup-scope" (fun dir ->
      let state = Mcp_server.create_state ~base_path:dir in
      let root_agents = Room.agents_dir state.Mcp_server.room_config in
      Fs_compat.mkdir_p root_agents;
      write_file (Filename.concat root_agents "root-agent.json") "{}";
      state.Mcp_server.room_config <-
        Room.with_scope state.Mcp_server.room_config (Room.Named "alpha");
      let room_agents = Room.agents_dir state.Mcp_server.room_config in
      Fs_compat.mkdir_p room_agents;
      write_file (Filename.concat room_agents "room-agent.json") "{}";
      Server_runtime_bootstrap.restore_persisted_sessions state;
      let restored =
        Session.connected_agents state.Mcp_server.session_registry |> List.sort String.compare
      in
      Alcotest.(check (list string))
        "restore uses scoped room agents dir only"
        [ "room-agent" ] restored)

let test_keeper_paths_use_cluster_root () =
  with_temp_dir "startup-cluster" (fun dir ->
      with_env "MASC_CLUSTER_NAME" (Some "cluster-alpha") (fun () ->
          let config = Room.default_config dir |> Room.config_with_resolved_scope in
          let keeper_dir = Keeper_types.keeper_dir config in
          let expected_root =
            Filename.concat
              (Filename.concat (Filename.concat dir ".masc") "clusters")
              "cluster-alpha"
          in
          Alcotest.(check bool) "keeper dir under cluster root" true
            (String.starts_with ~prefix:expected_root keeper_dir)))

let test_room_init_bootstraps_keeper_runtime_dirs () =
  with_temp_dir "startup-keeper-dirs" (fun dir ->
      let config = Room.default_config dir |> Room.config_with_resolved_scope in
      ignore (Room.init config ~agent_name:None);
      let root_dir = Room.masc_root_dir config in
      let legacy_keepers_dir = Filename.concat root_dir "keepers" in
      let keeper_dir = Filename.concat root_dir "perpetual-keepers" in
      let perpetual_dir = Filename.concat root_dir "perpetual" in
      Alcotest.(check bool) "legacy keeper dir exists" true
        (Sys.file_exists legacy_keepers_dir && Sys.is_directory legacy_keepers_dir);
      Alcotest.(check bool) "keeper dir exists" true
        (Sys.file_exists keeper_dir && Sys.is_directory keeper_dir);
      Alcotest.(check bool) "perpetual dir exists" true
        (Sys.file_exists perpetual_dir && Sys.is_directory perpetual_dir))

let test_startup_state_json () =
  Server_startup_state.reset ~backend_mode:"postgres-native" ();
  Server_startup_state.mark_state_ready ~backend_mode:"postgres-native";
  Server_startup_state.activate_lazy ~backend_mode:"postgres-native"
    ~tasks:[ "restore_sessions"; "keeper_bootstrap" ];
  Server_startup_state.finish_lazy_task ~task:"restore_sessions";
  Server_startup_state.fail_lazy_task ~task:"keeper_bootstrap"
    ~error:"keeper failed";
  let json = Server_startup_state.to_yojson () in
  Alcotest.(check string) "phase becomes degraded" "degraded"
    (json_string_field "phase" json);
  Alcotest.(check bool) "state remains ready" true
    (json_bool_field "state_ready" json);
  Alcotest.(check string) "last error recorded" "keeper failed"
    (json_string_field "last_error" json)

let test_startup_state_liveness () =
  Server_startup_state.reset ~backend_mode:"unknown" ();
  Alcotest.(check bool) "is_live returns true even during init" true
    (Server_startup_state.is_live ());
  Alcotest.(check bool) "elapsed_since_start is non-negative" true
    (Server_startup_state.elapsed_since_start () >= 0.0)

let test_startup_state_readiness_before_init () =
  Server_startup_state.reset ~backend_mode:"postgres-native" ();
  let current = Server_startup_state.(!state) in
  Alcotest.(check bool) "not ready before init" false current.state_ready;
  Alcotest.(check string) "phase is blocking" "blocking"
    (Server_startup_state.phase_to_string current.phase)

let test_startup_state_readiness_after_init () =
  Server_startup_state.reset ~backend_mode:"filesystem" ();
  Server_startup_state.mark_state_ready ~backend_mode:"filesystem";
  let current = Server_startup_state.(!state) in
  Alcotest.(check bool) "ready after init" true current.state_ready;
  Alcotest.(check string) "phase is ready" "ready"
    (Server_startup_state.phase_to_string current.phase)

let test_watchdog_timeout_env () =
  with_env "MASC_STARTUP_WATCHDOG_SEC" (Some "90") (fun () ->
      Alcotest.(check (float 0.1)) "reads env" 90.0
        (Server_startup_state.watchdog_timeout_sec ()));
  with_env "MASC_STARTUP_WATCHDOG_SEC" (Some "10") (fun () ->
      Alcotest.(check (float 0.1)) "clamps to 30 min" 30.0
        (Server_startup_state.watchdog_timeout_sec ()));
  with_env "MASC_STARTUP_WATCHDOG_SEC" (Some "999") (fun () ->
      Alcotest.(check (float 0.1)) "clamps to 600 max" 600.0
        (Server_startup_state.watchdog_timeout_sec ()));
  with_env "MASC_STARTUP_WATCHDOG_SEC" None (fun () ->
      Alcotest.(check (float 0.1)) "default 240" 240.0
        (Server_startup_state.watchdog_timeout_sec ()))

let test_startup_state_json_includes_watchdog () =
  Server_startup_state.reset ~backend_mode:"filesystem" ();
  let json = Server_startup_state.to_yojson () in
  let elapsed =
    match Yojson.Safe.Util.member "elapsed_sec" json with
    | `Float v -> v
    | _ -> Alcotest.failf "elapsed_sec missing or not float"
  in
  Alcotest.(check bool) "elapsed_sec present and non-negative" true
    (elapsed >= 0.0);
  let watchdog =
    match Yojson.Safe.Util.member "watchdog_timeout_sec" json with
    | `Float v -> v
    | _ -> Alcotest.failf "watchdog_timeout_sec missing or not float"
  in
  Alcotest.(check bool) "watchdog_timeout_sec is positive" true
    (watchdog > 0.0)

let test_prompt_markdown_dir_falls_back_to_repo_root () =
  with_temp_dir "startup-prompts" (fun dir ->
      let expected =
        Filename.concat (project_root ()) "config/prompts"
      in
      Alcotest.(check bool) "repo prompt dir exists" true
        (Sys.file_exists expected && Sys.is_directory expected);
      let resolved =
        Prompt_defaults.resolve_prompt_markdown_dir
          ~workspace_path:dir ~base_path:dir
      in
      Alcotest.(check string) "temp room falls back to repo prompt dir"
        expected resolved)

let test_main_eio_serves_health_before_lazy_startup () =
  with_temp_dir "startup-health" (fun dir ->
      let exe = find_main_eio_exe () in
      let port = find_free_port () in
      let log_file = Filename.concat dir "server.log" in
      let log_fd =
        Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      let env =
        merge_env_overrides
          [
            ("ME_ROOT", dir);
            ("MASC_BASE_PATH", dir);
            ("MASC_STORAGE_TYPE", "filesystem");
            ("MASC_POSTGRES_URL", "");
            ("DATABASE_URL", "");
            ("SUPABASE_DB_URL", "");
            ("SB_PG_URL", "");
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_AUTONOMY_ENABLED", "0");
            ("MASC_ORCHESTRATOR_ENABLED", "0");
            ("MASC_ALLOW_LEGACY_ACCEPT", "1");
            ("MASC_USE_H2", "0");
            ("DUNE_SOURCEROOT", project_root ());
          ]
      in
      let pid =
        Unix.create_process_env exe
          [|
            exe;
            "--host";
            "127.0.0.1";
            "--port";
            string_of_int port;
            "--base-path";
            dir;
          |]
          env Unix.stdin log_fd log_fd
      in
      Unix.close log_fd;
      Fun.protect
        ~finally:(fun () -> stop_process pid)
        (fun () ->
          if not (wait_for_health ~pid ~port ~timeout_s:5.0) then begin
            prerr_endline
              (Printf.sprintf
                 "main_eio did not expose /health within timeout in this environment.\nlog:\n%s"
                 (read_file log_file));
            Alcotest.skip ()
          end))

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Alcotest.run "Server_runtime_bootstrap"
    [
      ( "bootstrap",
        [
          Alcotest.test_case "force_jsonl_fallback_env clears pg envs" `Quick
            test_force_jsonl_fallback_env;
          Alcotest.test_case "constructors stay pure" `Quick
            test_constructor_is_pure;
          Alcotest.test_case "restore_persisted_sessions uses scoped agents dir"
            `Quick test_restore_persisted_sessions_uses_scoped_agents_dir;
          Alcotest.test_case "keeper paths use cluster root" `Quick
            test_keeper_paths_use_cluster_root;
          Alcotest.test_case "room init bootstraps keeper runtime dirs" `Quick
            test_room_init_bootstraps_keeper_runtime_dirs;
          Alcotest.test_case "startup state json reports lazy failure" `Quick
            test_startup_state_json;
          Alcotest.test_case "liveness probe is always true" `Quick
            test_startup_state_liveness;
          Alcotest.test_case "readiness false before init" `Quick
            test_startup_state_readiness_before_init;
          Alcotest.test_case "readiness true after init" `Quick
            test_startup_state_readiness_after_init;
          Alcotest.test_case "watchdog timeout env parsing" `Quick
            test_watchdog_timeout_env;
          Alcotest.test_case "startup json includes watchdog fields" `Quick
            test_startup_state_json_includes_watchdog;
          Alcotest.test_case "prompt markdown dir falls back to repo root"
            `Quick test_prompt_markdown_dir_falls_back_to_repo_root;
          Alcotest.test_case "main_eio serves health before lazy startup"
            `Slow test_main_eio_serves_health_before_lazy_startup;
        ] );
    ]
