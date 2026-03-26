open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()

let temp_dir () =
  let dir = Filename.temp_file "test_tool_mdal_pg_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let parse_json_exn s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> failwith ("invalid json: " ^ e)

let dispatch_exn ctx ~name ~args =
  match Tool_mdal.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

let reset_loop_registry () =
  Hashtbl.clear Tool_mdal.active_loops;
  Tool_mdal.latest_loop_id := None

let strict_runner () : Mdal_worker.runner =
 fun ~config:_ _state ~current_metric:_ ->
  Ok
    {
      Mdal_worker.prompt = "worker-prompt";
      report =
        {
          changes = "Resume from postgres hydration";
          failed_attempts = "";
          next_suggestion = "Keep iterating";
        };
      evidence =
        {
          Mdal.engine = `Api_tool_loop;
          model_used = "claude:test-mdal-pg";
          tool_call_count = 1;
          tool_names = [ "masc_spawn" ];
          session_id = "session-mdal-pg";
          status = `Verified;
        };
      cost_usd = Some 0.02;
    }

let make_ctx ?config ?worker_runner () : Tool_mdal.context =
  { agent_name = "tester"; config; sw = None; proc_mgr = None; worker_runner; clock = None }

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let with_envs bindings f =
  List.fold_right (fun (name, value) acc -> fun () -> with_env name value acc) bindings f ()

let pg_source () =
  [ "SB_PG_URL"; "SUPABASE_DB_URL"; "MASC_POSTGRES_URL"; "DATABASE_URL" ]
  |> List.find_map (fun name ->
         match Sys.getenv_opt name with
         | Some value when String.trim value <> "" -> Some (name, value)
         | _ -> None)

let cluster_name () =
  Printf.sprintf "mdal-pg-%d-%06d" (Unix.getpid ()) (Random.int 1_000_000)

let clear_backend_namespace config =
  match Room.backend_list_keys config ~prefix:"" with
  | Ok keys ->
      List.iter (fun key -> ignore (Room.backend_delete config ~key)) keys
  | Error _ -> ()

let with_pg_room f () =
  match pg_source () with
  | None -> Alcotest.skip ()
  | Some (source_name, url) ->
      let bindings =
        [
          ("MASC_STORAGE_TYPE", None);
          ("MASC_CLUSTER_NAME", Some (cluster_name ()));
          ("MASC_POSTGRES_URL", if source_name = "MASC_POSTGRES_URL" then Some url else None);
          ("DATABASE_URL", if source_name = "DATABASE_URL" then Some url else None);
          ("SUPABASE_DB_URL", if source_name = "SUPABASE_DB_URL" then Some url else None);
          ("SB_PG_URL", if source_name = "SB_PG_URL" then Some url else None);
        ]
      in
      with_envs bindings (fun () ->
          Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
          Eio.Switch.run @@ fun sw ->
          reset_loop_registry ();
          let base_dir = temp_dir () in
          let effective_url =
            match Room_utils.postgres_url_from_env () with
            | Some value -> value
            | None -> failwith "postgres_url_from_env returned None inside pg smoke"
          in
          let stdenv = (env :> Caqti_eio.stdenv) in
          let config = Room.default_config_eio ~sw ~env:stdenv base_dir in
          ignore (Room.init config ~agent_name:(Some "tester"));
          let ctx = make_ctx ~config ~worker_runner:(strict_runner ()) () in
          Fun.protect
            ~finally:(fun () ->
              clear_backend_namespace config;
              cleanup_dir base_dir;
              reset_loop_registry ())
            (fun () -> f ~source_name ~url ~effective_url ~config ~ctx))

let test_mdal_roundtrip_uses_postgres_backend =
  with_pg_room (fun ~source_name ~url:_ ~effective_url ~config ~ctx ->
      Alcotest.(check bool) "detected backend type" true
        (match config.Room.backend_config.backend_type with
         | Backend_types.PostgresNative -> true
         | _ -> false);
      Alcotest.(check (option string)) "resolved postgres url" (Some effective_url)
        config.Room.backend_config.postgres_url;
      if not (String.equal (Mdal_store.persistence_backend config) "postgres") then
        Alcotest.skip ()
      else
        Alcotest.(check string) "mdal store backend" "postgres"
          (Mdal_store.persistence_backend config);

      let ok_start, start_body =
        dispatch_exn ctx ~name:"masc_mdal_start"
          ~args:
            (`Assoc
              [
                ("profile", `String "custom");
                ("metric_fn", `String "printf '0.5\\n'");
                ("goal", `String "metric > 0.6");
                ("target", `String ("Postgres smoke via " ^ source_name));
              ])
      in
      Alcotest.(check bool) "start ok" true ok_start;
      let start_json = parse_json_exn start_body in
      Alcotest.(check string) "start backend" "postgres"
        (start_json |> Yojson.Safe.Util.member "persistence_backend"
        |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "strict mode" true
        (start_json |> Yojson.Safe.Util.member "strict_mode"
        |> Yojson.Safe.Util.to_bool);
      let loop_id =
        start_json |> Yojson.Safe.Util.member "loop_id" |> Yojson.Safe.Util.to_string
      in

      reset_loop_registry ();
      let ok_status, status_body =
        dispatch_exn ctx ~name:"masc_mdal_status"
          ~args:(`Assoc [ ("loop_id", `String loop_id) ])
      in
      Alcotest.(check bool) "status ok" true ok_status;
      let status_json = parse_json_exn status_body in
      Alcotest.(check string) "hydrated status interrupted" "interrupted"
        (status_json |> Yojson.Safe.Util.member "status"
        |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "recoverable" true
        (status_json |> Yojson.Safe.Util.member "recoverable"
        |> Yojson.Safe.Util.to_bool);
      Alcotest.(check string) "stop reason" "server_restart"
        (status_json |> Yojson.Safe.Util.member "stop_reason"
        |> Yojson.Safe.Util.to_string);

      reset_loop_registry ();
      let ok_iter, iter_body =
        dispatch_exn ctx ~name:"masc_mdal_iterate"
          ~args:(`Assoc [ ("loop_id", `String loop_id) ])
      in
      Alcotest.(check bool) "iterate ok" true ok_iter;
      let iter_json = parse_json_exn iter_body in
      Alcotest.(check string) "iterate status running" "running"
        (iter_json |> Yojson.Safe.Util.member "status"
        |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "iterate mode" "strict_worker"
        (iter_json |> Yojson.Safe.Util.member "iteration_mode"
        |> Yojson.Safe.Util.to_string);
      Alcotest.(check int) "tool count" 1
        (iter_json |> Yojson.Safe.Util.member "tool_call_count"
        |> Yojson.Safe.Util.to_int);
      Alcotest.(check (list string)) "tool names" [ "masc_spawn" ]
        (iter_json |> Yojson.Safe.Util.member "tool_names"
        |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string);
      Alcotest.(check string) "evidence status" "verified"
        (iter_json |> Yojson.Safe.Util.member "evidence_status"
        |> Yojson.Safe.Util.to_string))

let () =
  Alcotest.run "Tool_mdal_pg"
    [
      ( "postgres smoke",
        [
          Alcotest.test_case "roundtrip uses postgres backend" `Quick
            test_mdal_roundtrip_uses_postgres_backend;
        ] );
    ]
