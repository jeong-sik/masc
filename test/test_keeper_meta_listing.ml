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

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let write_keeper_toml_exn ?autoboot_enabled config ~name =
  let keepers_dir =
    Filename.concat (Coord.masc_root_dir config) "config/keepers"
  in
  let autoboot_line =
    match autoboot_enabled with
    | Some value -> Printf.sprintf "autoboot_enabled = %b\n" value
    | None -> ""
  in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.save_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    (Printf.sprintf
       "[keeper]\n\
        goal = \"test keeper\"\n\
        %s\
        proactive_enabled = false\n"
       autoboot_line)

let write_keeper_meta_exn ?(autoboot_enabled = true)
    ?(social_model = "bdi_speech_v1")
    ?(last_social_transition_reason = "") config ~name ~trace_id =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
        ("trace_id", `String trace_id);
        ("goal", `String "test keeper");
        ("social_model", `String social_model);
        ("last_social_transition_reason", `String last_social_transition_reason);
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

let register_keeper_offline_exn config ~name =
  match Keeper_types.read_meta config name with
  | Ok (Some meta) ->
      ignore
        (Keeper_registry.register_offline ~base_path:config.base_path name meta)
  | Ok None -> fail ("expected keeper meta for " ^ name)
  | Error e -> fail ("read_meta failed: " ^ e)

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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      write_keeper_toml_exn config ~name:"sangsu";
      write_keeper_toml_exn config ~name:"dot.name";
      let config_root = Filename.concat (Coord.masc_root_dir config) "config" in
      Unix.putenv "MASC_CONFIG_DIR" config_root;
      Config_dir_resolver.reset ();
      write_keeper_meta_exn config ~name:"sangsu" ~trace_id:"trace-sangsu";
      write_keeper_meta_exn config ~name:"dot.name" ~trace_id:"trace-dot-name";
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      write_keeper_toml_exn config ~name:"sangsu";
      let config_root = Filename.concat (Coord.masc_root_dir config) "config" in
      Unix.putenv "MASC_CONFIG_DIR" config_root;
      Config_dir_resolver.reset ();
      write_keeper_meta_exn
        ~autoboot_enabled:false config ~name:"sangsu" ~trace_id:"trace-sangsu";
      let names = Keeper_runtime.bootable_keeper_names config in
      check bool "autoboot disabled sangsu excluded from bootable list" false
        (List.mem "sangsu" names))

let test_declarative_autoboot_disabled_skips_boot_without_meta () =
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      write_keeper_toml_exn ~autoboot_enabled:false config ~name:"sangsu";
      let config_root = Filename.concat (Coord.masc_root_dir config) "config" in
      Unix.putenv "MASC_CONFIG_DIR" config_root;
      Config_dir_resolver.reset ();
      let bootable_names = Keeper_runtime.bootable_keeper_names config in
      check bool "bootable list excludes declarative autoboot-disabled keeper" false
        (List.mem "sangsu" bootable_names);
      let keepalive_names = Keeper_types.keepalive_keeper_names config in
      check bool "keepalive list excludes declarative autoboot-disabled keeper" false
        (List.mem "sangsu" keepalive_names))

let test_autoboot_policy_resync_from_declarative_toml () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  with_clean_base_path_env @@ fun () ->
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Cascade_catalog_runtime.reset_cache_for_tests ();
      Config_dir_resolver.reset ();
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      write_keeper_toml_exn ~autoboot_enabled:false config ~name:"sangsu";
      let config_root = Filename.concat (Coord.masc_root_dir config) "config" in
      let cascade_path = Filename.concat config_root "cascade.json" in
      write_file
        cascade_path
        {|{
  "big_three_models": ["test-only:model"]
}|};
      Unix.putenv "MASC_CONFIG_DIR" config_root;
      Config_dir_resolver.reset ();
      Cascade_catalog_runtime.install_snapshot_for_tests
        ~source_path:cascade_path
        ~profile_names:[ Keeper_config.default_cascade_name ];
      write_keeper_meta_exn
        ~autoboot_enabled:true config ~name:"sangsu" ~trace_id:"trace-sangsu";
      match Keeper_runtime.ensure_keeper_meta config "sangsu" with
      | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
      | Ok updated ->
          check bool "autoboot_enabled resynced from TOML" false
            updated.Keeper_types.autoboot_enabled)

let test_keeper_up_uses_toml_autoboot_default () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  with_clean_base_path_env @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "toml-autoboot-default" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Config_dir_resolver.reset ();
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      write_keeper_toml_exn ~autoboot_enabled:false config ~name:keeper_name;
      let config_root = Filename.concat (Coord.masc_root_dir config) "config" in
      Unix.putenv "MASC_CONFIG_DIR" config_root;
      Config_dir_resolver.reset ();
      let ctx = keeper_ctx env sw config "operator" in
      let ok, body =
        match
          Tool_keeper.dispatch ctx ~name:"masc_keeper_up"
            ~args:(`Assoc [ ("name", `String keeper_name) ])
        with
        | Some result -> result
        | None -> fail "expected masc_keeper_up dispatch"
      in
      check bool "keeper_up ok" true ok;
      match Keeper_types.read_meta config keeper_name with
      | Ok (Some meta) ->
          check bool "autoboot_enabled defaulted from TOML" false
            meta.autoboot_enabled
      | Ok None -> fail "keeper meta missing after keeper_up"
      | Error e -> fail ("read_meta failed: " ^ e))

let test_keeper_list_normalizes_unknown_social_model () =
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      write_keeper_toml_exn config ~name:"sangsu";
      write_keeper_meta_exn config ~name:"sangsu" ~trace_id:"trace-sangsu"
        ~social_model:"experimental_v99";
      register_keeper_offline_exn config ~name:"sangsu";
      let ctx = keeper_ctx env sw config "operator" in
      let ok, body =
        match
          Tool_keeper.dispatch ctx ~name:"masc_keeper_list"
            ~args:(`Assoc [ ("limit", `Int 10); ("detailed", `Bool true) ])
        with
        | Some result -> result
        | None -> fail "expected masc_keeper_list dispatch"
      in
      check bool "tool keeper list ok" true ok;
      let json = parse_json_exn body in
      match keeper_json_by_name json "sangsu" with
      | Some keeper ->
          check string "social_model normalized" "bdi_speech_v1"
            Yojson.Safe.Util.(keeper |> member "social_model" |> to_string);
          check string "configured_social_model preserved" "experimental_v99"
            Yojson.Safe.Util.(keeper |> member "configured_social_model" |> to_string);
          check bool "social_model_recognized false" false
            Yojson.Safe.Util.(keeper |> member "social_model_recognized" |> to_bool);
          check string "social_model_fallback explicit" "bdi_speech_v1"
            Yojson.Safe.Util.(keeper |> member "social_model_fallback" |> to_string)
      | None -> fail "expected sangsu row in keeper list")

let test_keeper_list_exposes_last_social_transition_reason () =
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      write_keeper_toml_exn config ~name:"sangsu";
      write_keeper_meta_exn config ~name:"sangsu" ~trace_id:"trace-sangsu"
        ~last_social_transition_reason:"tool_only:visible_reply";
      register_keeper_offline_exn config ~name:"sangsu";
      let ctx = keeper_ctx env sw config "operator" in
      let ok, body =
        match
          Tool_keeper.dispatch ctx ~name:"masc_keeper_list"
            ~args:(`Assoc [ ("limit", `Int 10); ("detailed", `Bool true) ])
        with
        | Some result -> result
        | None -> fail "expected masc_keeper_list dispatch"
      in
      check bool "tool keeper list ok" true ok;
      let json = parse_json_exn body in
      match keeper_json_by_name json "sangsu" with
      | Some keeper ->
          check string "transition reason surfaced" "tool_only:visible_reply"
            Yojson.Safe.Util.(
              keeper |> member "last_social_transition_reason" |> to_string)
      | None -> fail "expected sangsu row in keeper list")

let test_keeper_list_preserves_known_social_model () =
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      write_keeper_toml_exn config ~name:"sangsu";
      write_keeper_meta_exn config ~name:"sangsu" ~trace_id:"trace-sangsu"
        ~social_model:"magentic_ledger_v1";
      register_keeper_offline_exn config ~name:"sangsu";
      let ctx = keeper_ctx env sw config "operator" in
      let ok, body =
        match
          Tool_keeper.dispatch ctx ~name:"masc_keeper_list"
            ~args:(`Assoc [ ("limit", `Int 10); ("detailed", `Bool true) ])
        with
        | Some result -> result
        | None -> fail "expected masc_keeper_list dispatch"
      in
      check bool "tool keeper list ok" true ok;
      let json = parse_json_exn body in
      match keeper_json_by_name json "sangsu" with
      | Some keeper ->
          check string "known model preserved" "magentic_ledger_v1"
            Yojson.Safe.Util.(keeper |> member "social_model" |> to_string)
      | None -> fail "expected sangsu row in keeper list")

let () =
  run "keeper_meta_listing"
    [
      ( "listing",
        [
          test_case "keeper_names and keeper_list ignore sidecar json" `Quick
            test_keeper_listing_ignores_sidecar_json_files;
          test_case "bootable list skips autoboot-disabled meta" `Quick
            test_bootable_keeper_names_skip_autoboot_disabled_meta;
          test_case "declarative autoboot-disabled keeper skips boot without meta"
            `Quick test_declarative_autoboot_disabled_skips_boot_without_meta;
          test_case "autoboot policy resyncs from declarative TOML" `Quick
            test_autoboot_policy_resync_from_declarative_toml;
          test_case "keeper_up uses TOML autoboot default" `Quick
            test_keeper_up_uses_toml_autoboot_default;
          test_case "tool keeper list normalizes unknown social model" `Quick
            test_keeper_list_normalizes_unknown_social_model;
          test_case "tool keeper list preserves known social model" `Quick
            test_keeper_list_preserves_known_social_model;
          test_case "tool keeper list exposes last social transition reason"
            `Quick test_keeper_list_exposes_last_social_transition_reason;
        ] );
    ]
