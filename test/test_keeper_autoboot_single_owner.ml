open Alcotest

module Workspace = Masc.Workspace
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module Keeper_runtime = Masc.Keeper_runtime
module Keeper_registry = Masc.Keeper_registry

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let write_file path content =
  Out_channel.with_open_bin path (fun channel -> output_string channel content)
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

let write_keeper_toml ?autoboot_enabled config_root ~name =
  let keepers_dir = Filename.concat config_root "keepers" in
  mkdir_p keepers_dir;
  let autoboot_line =
    match autoboot_enabled with
    | None -> ""
    | Some value ->
      Printf.sprintf "autoboot_enabled = %s\n" (string_of_bool value)
  in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    (Printf.sprintf
       {|
[keeper]
name = "%s"
instructions = "test keeper"
%s
|}
       name
       autoboot_line)
;;

let make_meta ?(paused = false) name =
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
      ; "trace_id", `String ("trace-" ^ name)
      ; "sandbox_profile", `String "local"
      ; "network_mode", `String "inherit"
      ]
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Error error -> fail ("meta_of_json failed: " ^ error)
  | Ok meta -> { meta with paused }
;;

let write_meta_exn config meta =
  match Keeper_meta_store.write_meta config meta with
  | Ok () -> ()
  | Error error -> fail ("write_meta failed: " ^ error)
;;

let config_root config =
  Filename.concat (Workspace.masc_root_dir config) "config"
;;

let test_configured_keeper_names_use_workspace_base_path () =
  let base_a = Filename.temp_dir "masc-autoboot-a-" "" in
  let base_b = Filename.temp_dir "masc-autoboot-b-" "" in
  let config_a = Workspace.default_config base_a in
  let config_b = Workspace.default_config base_b in
  let original_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  let original_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" original_config_dir;
      restore_env "MASC_BASE_PATH" original_base_path;
      Config_dir_resolver.reset ();
      remove_tree base_a;
      remove_tree base_b)
    (fun () ->
      write_keeper_toml (config_root config_a) ~name:"alpha";
      write_keeper_toml (config_root config_b) ~name:"bravo";
      write_keeper_toml
        (config_root config_a)
        ~name:"shared"
        ~autoboot_enabled:true;
      write_keeper_toml
        (config_root config_b)
        ~name:"shared"
        ~autoboot_enabled:false;
      Unix.putenv "MASC_CONFIG_DIR" "";
      Unix.putenv "MASC_BASE_PATH" base_b;
      Config_dir_resolver.reset ();
      check
        (list string)
        "ambient resolver observes the other workspace"
        [ "bravo"; "shared" ]
        (Masc.Keeper_types_profile.discover_keepers_toml
           (Config_dir_resolver.keepers_dir ())
         |> List.map Masc.Keeper_types_profile.keeper_toml_discovery_name);
      check
        (list string)
        "autoboot discovery remains owned by Workspace.config"
        [ "alpha"; "shared" ]
        (Keeper_meta_store.configured_keeper_names config_a);
      check
        (list string)
        "boot admission remains owned by Workspace.config"
        [ "alpha"; "shared" ]
        (Keeper_runtime.bootable_keeper_names config_a))
;;

let test_operator_paused_keeper_is_not_bootable () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "masc-autoboot-paused-" "" in
  let config = Workspace.default_config base_path in
  let keeper_name = "manual-only" in
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      Keeper_registry.For_testing.clear ();
      Keeper_runtime.reset_test_state base_path;
      remove_tree base_path)
    (fun () ->
      write_keeper_toml (config_root config) ~name:keeper_name;
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
    "keeper autoboot ownership"
    [ ( "policy"
      , [ test_case
            "Workspace.config owns autoboot discovery"
            `Quick
            test_configured_keeper_names_use_workspace_base_path
        ; test_case
            "operator pause survives restart admission"
            `Quick
            test_operator_paused_keeper_is_not_bootable
        ] )
    ]
;;
