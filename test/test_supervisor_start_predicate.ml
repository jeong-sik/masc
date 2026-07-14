(* #10125: pin [should_start_supervisor_sweep] decision logic.
   Pre-fix the gate required [stats.enabled = true]; a transient
   bootstrap failure (every keeper meta hit a load error) made the
   supervisor never start, so the sweep that would otherwise
   recover those keepers never ran — fleet stayed dead 4h+.

   Post-fix: [stats.enabled] is no longer load-bearing.  Bootable
   keepers on disk OR running count > 0 OR started > 0 each
   independently force the supervisor up.  This is what protects
   us from a degenerate bootstrap.

   Note on test isolation: keeper TOML discovery must be scoped to the
   supplied [Workspace.config.base_path].  The tests below pin that
   path ownership so an ambient [MASC_BASE_PATH] from another runtime
   cannot silently redirect supervisor boot decisions. *)

open Alcotest

module Workspace = Masc.Workspace
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module KR = Masc.Keeper_runtime
module KT = Keeper_types
module Reg = Masc.Keeper_registry

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else
      Sys.remove path

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

let write_keeper_toml ?autoboot_enabled config_root ~name =
  let keepers_dir = Filename.concat config_root "keepers" in
  mkdir_p keepers_dir;
  let autoboot_line =
    match autoboot_enabled with
    | None -> ""
    | Some value -> Printf.sprintf "autoboot_enabled = %s\n" (string_of_bool value)
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

let make_meta ?(paused = false) name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String ("keeper-" ^ name ^ "-agent"))
      ; ("trace_id", `String ("trace-" ^ name))
      ; ("sandbox_profile", `String "local")
      ; ("network_mode", `String "inherit")
      ]
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Error err -> fail ("meta_of_json failed: " ^ err)
  | Ok meta -> { meta with paused }

let write_meta_exn config meta =
  match Keeper_meta_store.write_meta config meta with
  | Ok () -> ()
  | Error err -> fail ("write_meta failed: " ^ err)

let fresh_temp_dir prefix =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir path 0o755;
  path

let with_temp_masc_dir ?(keeper_names = [ "operator" ]) f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = fresh_temp_dir "masc-10125" in
  let config = Workspace.default_config base in
  let config_root = Filename.concat (Workspace.masc_root_dir config) "config" in
  let original_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  mkdir_p config_root;
  List.iter (fun name -> write_keeper_toml config_root ~name) keeper_names;
  Unix.putenv "MASC_CONFIG_DIR" config_root;
  Config_dir_resolver.reset ();
  ignore (Workspace.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      Reg.clear ();
      KR.reset_test_state base;
      restore_env "MASC_CONFIG_DIR" original_config_dir;
      Config_dir_resolver.reset ();
      rm_rf base)
    (fun () -> f config)

let test_configured_keeper_names_uses_workspace_base_path () =
  let base_a = fresh_temp_dir "masc-config-a" in
  let base_b = fresh_temp_dir "masc-config-b" in
  let config_a = Workspace.default_config base_a in
  let config_b = Workspace.default_config base_b in
  let config_root_a = Filename.concat (Workspace.masc_root_dir config_a) "config" in
  let config_root_b = Filename.concat (Workspace.masc_root_dir config_b) "config" in
  let original_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  let original_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" original_config_dir;
      restore_env "MASC_BASE_PATH" original_base_path;
      Config_dir_resolver.reset ();
      rm_rf base_a;
      rm_rf base_b)
    (fun () ->
      write_keeper_toml config_root_a ~name:"alpha";
      write_keeper_toml config_root_b ~name:"bravo";
      write_keeper_toml config_root_a ~name:"shared" ~autoboot_enabled:true;
      write_keeper_toml config_root_b ~name:"shared" ~autoboot_enabled:false;
      Unix.putenv "MASC_CONFIG_DIR" "";
      Unix.putenv "MASC_BASE_PATH" base_b;
      Config_dir_resolver.reset ();
      check (list string) "global resolver sees ambient base path"
        [ "bravo"; "shared" ]
        (Masc.Keeper_types_profile.discover_keepers_toml
           (Config_dir_resolver.keepers_dir ())
         |> List.map Masc.Keeper_types_profile.keeper_toml_discovery_name);
      check (list string) "configured keepers use Workspace.config base path"
        [ "alpha"; "shared" ]
        (Keeper_meta_store.configured_keeper_names config_a);
      check (list string) "boot policy uses Workspace.config defaults"
        [ "alpha"; "shared" ]
        (KR.bootable_keeper_names config_a))

(* The regression case the fix is for: bootstrap reported [enabled
   = false] AND [started = 0]. Pre-fix this killed the supervisor
   for the entire process lifetime (the [stats.enabled] AND-gate).
   Post-fix [has_boot_entries] alone is sufficient and keepers can
   be recovered by the sweep loop. *)
let test_disabled_bootstrap_with_disk_keepers_starts_sweep () =
  with_temp_masc_dir (fun config ->
    let stats =
      KR.{ scanned = 0; started = 0; stale = 0; recovering = 0 }
    in
    check bool
      "disabled bootstrap + disk keepers (operator profile) → true"
      true
      (KR.should_start_supervisor_sweep ~config ~stats))

(* Even without [enabled], a positive [started] count is enough.
   This covers the second post-fix invariant: the boot path
   produced at least one running keeper, so the sweep must
   monitor it regardless of how the bootstrap-stats record
   interpreted aggregate enabled-ness. *)
let test_started_gt_zero_starts_sweep_without_enabled () =
  with_temp_masc_dir (fun config ->
    let stats =
      KR.{ scanned = 1; started = 1; stale = 0; recovering = 0 }
    in
    check bool
      "stats.started > 0 even when enabled = false → true"
      true
      (KR.should_start_supervisor_sweep ~config ~stats))

(* Sanity check: predicate runs without raising on a fully
   defaulted [stats] record.  Pre-fix this would short-circuit on
   [enabled = false]; post-fix it falls through to
   [has_boot_entries], so we MUST not regress to raising or
   silently returning [false] on a real config. *)
let test_predicate_total_on_defaulted_stats () =
  with_temp_masc_dir (fun config ->
    let stats =
      KR.{ scanned = 0; started = 0; stale = 0; recovering = 0 }
    in
    let _ : bool = KR.should_start_supervisor_sweep ~config ~stats in
    ())

let test_operator_paused_only_does_not_start_sweep () =
  with_temp_masc_dir ~keeper_names:[ "manual-only" ] (fun config ->
    write_meta_exn config (make_meta ~paused:true "manual-only");
    let stats =
      KR.{ scanned = 0; started = 0; stale = 0; recovering = 0 }
    in
    check bool "operator-paused keeper is not bootable" false
      (List.mem "manual-only" (KR.bootable_keeper_names config));
    check bool "operator pause alone does not start sweep" false
      (KR.should_start_supervisor_sweep ~config ~stats))

let () =
  run "supervisor_start_predicate_10125" [
    "predicate", [
      test_case "configured keeper names use workspace base path" `Quick
        test_configured_keeper_names_uses_workspace_base_path;
      test_case "disabled bootstrap + disk keeper → true (regression fix)" `Quick
        test_disabled_bootstrap_with_disk_keepers_starts_sweep;
      test_case "stats.started > 0 even when enabled = false → true" `Quick
        test_started_gt_zero_starts_sweep_without_enabled;
      test_case "predicate is total on defaulted stats (no raise)" `Quick
        test_predicate_total_on_defaulted_stats;
      test_case "operator-paused keeper alone does not start sweep" `Quick
        test_operator_paused_only_does_not_start_sweep;
    ];
  ]
