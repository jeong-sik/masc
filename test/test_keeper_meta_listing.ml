open Alcotest
open Masc_mcp

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_meta_listing_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then
    Fs_compat.set_fs (Eio.Stdenv.fs env)

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect
    ~finally:restore
    (fun () ->
      (match value_opt with
       | Some value -> Unix.putenv name value
       | None -> Unix.putenv name "");
      f ())

let with_clean_base_path_env f =
  with_env "MASC_BASE_PATH" None @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
  with_env "MASC_CONFIG_DIR" None @@ fun () ->
  with_env "MASC_PERSONAS_DIR" None @@ fun () ->
  with_env "MASC_TEST_SYNCED_BASE_PATH" None @@ fun () ->
  with_env "MASC_BASE_PATH_RESOLUTION_SOURCE" None f

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let write_json path json =
  Out_channel.with_open_bin path (fun oc ->
      output_string oc (Yojson.Safe.pretty_to_string json))

let write_keeper_toml_exn config ~name =
  let keepers_dir =
    Filename.concat (Room.masc_root_dir config) "config/keepers"
  in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.save_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|
[keeper]
goal = "test keeper"
room_scope = "current"
proactive_enabled = false
|}

let write_keeper_meta_exn ?(autoboot_enabled = true) config ~name ~trace_id =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
        ("trace_id", `String trace_id);
        ("goal", `String "test keeper");
        ("autoboot_enabled", `Bool autoboot_enabled);
      ]
  in
  let meta =
    match Keeper_types.meta_of_json json with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  match Keeper_types.write_meta ~force:true config meta with
  | Ok () -> ()
  | Error e -> fail ("write_meta failed: " ^ e)

let parse_json_exn body =
  try Yojson.Safe.from_string body
  with Yojson.Json_error err -> failwith ("invalid json: " ^ err)

let keeper_json_by_name json name =
  Yojson.Safe.Util.(json |> member "keepers" |> to_list)
  |> List.find_opt (fun keeper ->
         Yojson.Safe.Util.(keeper |> member "name" |> to_string = name))

let keeper_ctx env sw config agent_name : _ Tool_keeper.context =
  {
    config;
    agent_name;
    sw;
    clock = Eio.Stdenv.clock env;
    proc_mgr = Some (Eio.Stdenv.process_mgr env);
    net = None;
  }

let test_keeper_listing_ignores_sidecar_json_files () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  with_clean_base_path_env @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Config_dir_resolver.reset ();
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      write_keeper_toml_exn config ~name:"sangsu";
      write_keeper_toml_exn config ~name:"dot.name";
      let config_root = Filename.concat (Room.masc_root_dir config) "config" in
      Unix.putenv "MASC_CONFIG_DIR" config_root;
      Config_dir_resolver.reset ();
      write_keeper_meta_exn config ~name:"sangsu" ~trace_id:"trace-sangsu";
      write_keeper_meta_exn config ~name:"dot.name" ~trace_id:"trace-dot-name";
      ignore
        (Keeper_manual_reconcile.open_pending
           config
           ~keeper_name:"sangsu"
           ~blocker_class:"ambiguous_post_commit_failure"
           ~summary:"turn outcome ambiguous"
           ~failure_reason:(Some "manual reconcile required")
           ~trace_id:(Some "trace-sangsu")
           ~generation:(Some 1)
           ~committed_tools:["keeper_bash"]);
      let dataset_path =
        Filename.concat (Keeper_fs.keeper_dir config) "sangsu.dataset.json"
      in
      write_json dataset_path (`Assoc [ ("kind", `String "dataset") ]);
      let names = Keeper_types.keeper_names config in
      check (list string) "keeper_names filters sidecars"
        [ "dot.name"; "sangsu" ] names;
      let keepalive_names = Keeper_types.keepalive_keeper_names config in
      check (list string) "keepalive_keeper_names filters sidecars"
        [ "dot.name"; "sangsu" ] keepalive_names;
      let ctx = keeper_ctx env sw config "operator" in
      let ok, body =
        Keeper_status.handle_keeper_list ctx (`Assoc [ ("limit", `Int 10) ])
      in
      check bool "keeper status list ok" true ok;
      let json = parse_json_exn body in
      let listed =
        Yojson.Safe.Util.(json |> member "keepers" |> to_list |> filter_string)
      in
      check (list string) "status handler filters sidecars"
        [ "dot.name"; "sangsu" ] listed;
      check int "status handler count filters sidecars" 2
        Yojson.Safe.Util.(json |> member "count" |> to_int))

let test_dashboard_ignores_fileless_manual_reconcile_fallback () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  with_clean_base_path_env @@ fun () ->
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let meta_json =
        `Assoc
          [
            ("name", `String "sangsu");
            ("agent_name", `String "keeper-sangsu-agent");
            ("trace_id", `String "trace-sangsu");
            ("goal", `String "test keeper");
          ]
      in
      let meta =
        match Keeper_types.meta_of_json meta_json with
        | Ok meta -> meta
        | Error e -> fail ("meta_of_json failed: " ^ e)
      in
      (match Keeper_types.write_meta ~force:true config meta with
       | Ok () -> ()
       | Error e -> fail ("write_meta failed: " ^ e));
      ignore (Keeper_registry.register ~base_path:config.base_path meta.name meta);
      Keeper_registry.set_failure_reason ~base_path:config.base_path meta.name
        (Some
           (Keeper_registry.Ambiguous_partial_commit
              {
                kind = Keeper_registry.Post_commit_failure;
                detail =
                  "Mutating tools [keeper_board_comment, keeper_board_vote] committed before the turn failed; retry stayed disabled and manual reconcile is required.";
              }));
      let json = Dashboard_http_keeper.keepers_dashboard_json config in
      match keeper_json_by_name json "sangsu" with
      | None -> fail "sangsu missing from keepers dashboard json"
      | Some keeper ->
          check bool "reconcile_status stays null without record" true
            Yojson.Safe.Util.(keeper |> member "reconcile_status" = `Null);
          check bool "runtime blocker class stays null without record" true
            Yojson.Safe.Util.(keeper |> member "runtime_blocker_class" = `Null);
          check bool "runtime blocker manual_reconcile stays null without record" true
            Yojson.Safe.Util.(keeper |> member "runtime_blocker_manual_reconcile" = `Null))

let test_dashboard_ignores_fileless_unsafe_manual_reconcile_fallback () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let meta_json =
        `Assoc
          [
            ("name", `String "sangsu");
            ("agent_name", `String "keeper-sangsu-agent");
            ("trace_id", `String "trace-sangsu");
            ("goal", `String "test keeper");
          ]
      in
      let meta =
        match Keeper_types.meta_of_json meta_json with
        | Ok meta -> meta
        | Error e -> fail ("meta_of_json failed: " ^ e)
      in
      (match Keeper_types.write_meta ~force:true config meta with
       | Ok () -> ()
       | Error e -> fail ("write_meta failed: " ^ e));
      ignore (Keeper_registry.register ~base_path:config.base_path meta.name meta);
      Keeper_registry.set_failure_reason ~base_path:config.base_path meta.name
        (Some
           (Keeper_registry.Ambiguous_partial_commit
              {
                kind = Keeper_registry.Post_commit_failure;
                detail =
                  "Mutating tools [keeper_fs_edit] committed before the turn failed; retry stayed disabled and manual reconcile is required.";
              }));
      let json = Dashboard_http_keeper.keepers_dashboard_json config in
      match keeper_json_by_name json "sangsu" with
      | None -> fail "sangsu missing from keepers dashboard json"
      | Some keeper ->
          check bool "unsafe reconcile_status stays null without record" true
            Yojson.Safe.Util.(keeper |> member "reconcile_status" = `Null);
          check bool "unsafe runtime blocker class stays null without record" true
            Yojson.Safe.Util.(keeper |> member "runtime_blocker_class" = `Null);
          check bool "unsafe runtime blocker manual_reconcile stays null without record" true
            Yojson.Safe.Util.(keeper |> member "runtime_blocker_manual_reconcile" = `Null))

let test_bootable_keeper_names_skip_autoboot_disabled_meta () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  with_clean_base_path_env @@ fun () ->
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Config_dir_resolver.reset ();
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      write_keeper_toml_exn config ~name:"sangsu";
      let config_root = Filename.concat (Room.masc_root_dir config) "config" in
      Unix.putenv "MASC_CONFIG_DIR" config_root;
      Config_dir_resolver.reset ();
      write_keeper_meta_exn
        ~autoboot_enabled:false config ~name:"sangsu" ~trace_id:"trace-sangsu";
      let names = Keeper_runtime.bootable_keeper_names config in
      check bool "autoboot disabled sangsu excluded from bootable list" false
        (List.mem "sangsu" names))

let () =
  run "keeper_meta_listing"
    [
      ( "listing",
        [
          test_case "keeper_names and keeper_list ignore sidecar json" `Quick
            test_keeper_listing_ignores_sidecar_json_files;
          test_case "dashboard ignores file-less reconcile fallback" `Quick
            test_dashboard_ignores_fileless_manual_reconcile_fallback;
          test_case "dashboard ignores file-less unsafe reconcile fallback" `Quick
            test_dashboard_ignores_fileless_unsafe_manual_reconcile_fallback;
          test_case "bootable list skips autoboot-disabled meta" `Quick
            test_bootable_keeper_names_skip_autoboot_disabled_meta;
        ] );
    ]
