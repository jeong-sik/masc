open Alcotest
open Masc

let write_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> output_string channel content)
;;

let write_keeper_toml ~base_path ~name ~autoboot_enabled =
  let path =
    Filename.concat
      (Config_dir_resolver.keepers_dir_for_base_path ~base_path)
      (name ^ ".toml")
  in
  write_file
    path
    (Printf.sprintf
       "[keeper]\nname = %S\ninstructions = \"test keeper\"\nautoboot_enabled = %b\nsandbox_profile = \"local\"\n"
       name
       autoboot_enabled)
;;

let with_temp_dir prefix f =
  let path = Filename.temp_dir prefix ".workspace" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
;;

let make_meta ?(paused = false) name =
  let json =
    `Assoc
      [ "name", `String name
      ; "trace_id", `String ("trace-" ^ name)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> { meta with paused }
  | Error error -> fail ("meta_of_json failed: " ^ error)
;;

let write_meta_exn config meta =
  match Keeper_meta_store.replace_snapshot config meta with
  | Ok () -> ()
  | Error error -> fail ("write_meta failed: " ^ error)
;;

let test_delegate_dispatch_does_not_autoboot_configured_peer () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-autoboot-owner-" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let peer = "autoboot-peer" in
  write_keeper_toml ~base_path ~name:peer ~autoboot_enabled:true;
  ignore (Workspace.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      Keeper_registry.For_testing.clear ();
      Keeper_runtime.reset_test_state base_path)
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = "test-caller"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = Some (Eio.Stdenv.net env)
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      let result =
        Keeper_tool_surface.dispatch
          ctx
          ~name:"masc_keeper_delegate"
          ~args:
            (`Assoc
               [ ( "target"
                 , `Assoc
                     [ "kind", `String "keeper"; "name", `String "missing-target" ]
                 )
               ; "capability", `String "invoke_turn"
               ; "prompt", `String "hello"
               ])
      in
      check bool "delegate request reaches its handler" true (Option.is_some result);
      check bool
        "tool dispatch does not start an unrelated configured keeper"
        false
        (Keeper_registry.is_registered ~base_path peer))
;;

let test_configured_keeper_names_use_workspace_base_path () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-autoboot-config-a-" @@ fun base_a ->
  with_temp_dir "masc-autoboot-config-b-" @@ fun base_b ->
  let config_a = Workspace.default_config base_a in
  let config_b = Workspace.default_config base_b in
  write_keeper_toml ~base_path:base_a ~name:"alpha" ~autoboot_enabled:true;
  write_keeper_toml ~base_path:base_a ~name:"shared" ~autoboot_enabled:true;
  write_keeper_toml ~base_path:base_b ~name:"bravo" ~autoboot_enabled:true;
  write_keeper_toml ~base_path:base_b ~name:"shared" ~autoboot_enabled:false;
  check
    (list string)
    "configured roster remains scoped to workspace A"
    [ "alpha"; "shared" ]
    (Keeper_meta_store.configured_keeper_names config_a);
  check
    (list string)
    "configured roster remains scoped to workspace B"
    [ "bravo"; "shared" ]
    (Keeper_meta_store.configured_keeper_names config_b);
  check
    (list string)
    "autoboot policy remains scoped to workspace A"
    [ "alpha"; "shared" ]
    (Keeper_runtime.bootable_keeper_names config_a);
  check
    (list string)
    "autoboot policy remains scoped to workspace B"
    [ "bravo" ]
    (Keeper_runtime.bootable_keeper_names config_b)
;;

let test_operator_paused_keeper_is_not_bootable () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-autoboot-paused-" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let keeper_name = "manual-only" in
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      Keeper_registry.For_testing.clear ();
      Keeper_runtime.reset_test_state base_path)
    (fun () ->
      write_keeper_toml ~base_path ~name:keeper_name ~autoboot_enabled:true;
      ignore (Workspace.init config ~agent_name:None);
      write_meta_exn config (make_meta ~paused:true keeper_name);
      check
        bool
        "paused keeper remains configured"
        true
        (List.mem keeper_name (Keeper_meta_store.configured_keeper_names config));
      check
        bool
        "operator pause excludes keeper from server-owned autoboot"
        false
        (List.mem keeper_name (Keeper_runtime.bootable_keeper_names config));
      match Keeper_runtime.autoboot_exclusion_reason config keeper_name with
      | Some Keeper_runtime.Paused -> ()
      | Some reason ->
        failf
          "paused keeper had the wrong exclusion reason: %s"
          (Keeper_runtime.autoboot_exclusion_reason_to_string reason)
      | None -> fail "paused keeper had no typed autoboot exclusion")
;;

let () =
  run
    "keeper autoboot single owner"
    [ ( "behavior"
      , [ test_case
            "delegate dispatch does not autoboot a configured peer"
            `Quick
            test_delegate_dispatch_does_not_autoboot_configured_peer
        ; test_case
            "configured roster uses workspace base path"
            `Quick
            test_configured_keeper_names_use_workspace_base_path
        ; test_case
            "operator pause survives restart admission"
            `Quick
            test_operator_paused_keeper_is_not_bootable
        ] )
    ]
;;
