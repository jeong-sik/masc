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

let project_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when String.trim root <> "" -> root
  | _ -> Sys.getcwd ()

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
      List.iter
        (fun name ->
          Alcotest.(check string)
            (Printf.sprintf "%s cleared" name) "" (Sys.getenv name))
        [ "MASC_POSTGRES_URL"; "DATABASE_URL"; "SUPABASE_DB_URL"; "SB_PG_URL" ])

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
          let resident_dir = Keeper_types.resident_keeper_dir config in
          let expected_root =
            Filename.concat
              (Filename.concat (Filename.concat dir ".masc") "clusters")
              "cluster-alpha"
          in
          Alcotest.(check bool) "keeper dir under cluster root" true
            (String.starts_with ~prefix:expected_root keeper_dir);
          Alcotest.(check bool) "resident dir under cluster root" true
            (String.starts_with ~prefix:expected_root resident_dir)))

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

let test_prompt_markdown_dir_falls_back_to_repo_root () =
  with_temp_dir "startup-prompts" (fun dir ->
      let expected =
        Filename.concat (project_root ()) "config/prompts"
      in
      Alcotest.(check bool) "repo prompt dir exists" true
        (Sys.file_exists expected && Sys.is_directory expected);
      let resolved =
        Server_runtime_bootstrap.resolve_prompt_markdown_dir
          ~workspace_path:dir ~base_path:dir
      in
      Alcotest.(check string) "temp room falls back to repo prompt dir"
        expected resolved)

let () =
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
          Alcotest.test_case "startup state json reports lazy failure" `Quick
            test_startup_state_json;
          Alcotest.test_case "prompt markdown dir falls back to repo root"
            `Quick test_prompt_markdown_dir_falls_back_to_repo_root;
        ] );
    ]
