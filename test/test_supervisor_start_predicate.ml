(* #10125: pin [should_start_supervisor_sweep] decision logic.
   Pre-fix the gate required [stats.enabled = true]; a transient
   bootstrap failure (every keeper meta hit a load error) made the
   supervisor never start, so the sweep that would otherwise
   recover those keepers never ran — fleet stayed dead 4h+.

   Post-fix: [stats.enabled] is no longer load-bearing.  Bootable
   keepers on disk OR running count > 0 OR started > 0 each
   independently force the supervisor up.  This is what protects
   us from a degenerate bootstrap.

   Note on test isolation: [Keeper_runtime.has_boot_entries] reads
   keeper TOML profiles via [Config_dir_resolver.keepers_dir ()],
   which is the active resolved config root independent of the
   [Coord.config.base_path].  So in every test environment with an
   active operator profile present,
   [bootable_keeper_names] returns non-empty.  The tests below
   exploit that — they verify the post-fix path
   ([enabled = false] still triggers sweep) without trying to
   construct an empty profile environment. *)

open Alcotest

module Coord = Masc_mcp.Coord
module KR = Masc_mcp.Keeper_runtime
module KT = Masc_mcp.Keeper_types
module Reg = Masc_mcp.Keeper_registry

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

let write_keeper_toml config_root ~name =
  let keepers_dir = Filename.concat config_root "keepers" in
  mkdir_p keepers_dir;
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    (Printf.sprintf
       {|
[keeper]
name = "%s"
goal = "test keeper"
|}
       name)

let iso_of_unix ts =
  let t = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (t.tm_year + 1900)
    (t.tm_mon + 1)
    t.tm_mday
    t.tm_hour
    t.tm_min
    t.tm_sec

let make_meta ?(paused = false) ?auto_resume_after_sec ?updated_at name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String ("keeper-" ^ name ^ "-agent"))
      ; ("trace_id", `String ("trace-" ^ name))
      ; ("goal", `String "test")
      ; ("sandbox_profile", `String "local")
      ; ("network_mode", `String "inherit")
      ]
  in
  match KT.meta_of_json json with
  | Error err -> fail ("meta_of_json failed: " ^ err)
  | Ok meta ->
    { meta with
      paused
    ; auto_resume_after_sec
    ; updated_at = Option.value ~default:meta.updated_at updated_at
    }

let write_meta_exn config meta =
  match KT.write_meta config meta with
  | Ok () -> ()
  | Error err -> fail ("write_meta failed: " ^ err)

let with_temp_masc_dir ?(keeper_names = [ "operator" ]) f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-10125-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  let config = Coord.default_config base in
  let config_root = Filename.concat (Coord.masc_root_dir config) "config" in
  let original_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  mkdir_p config_root;
  List.iter (fun name -> write_keeper_toml config_root ~name) keeper_names;
  Unix.putenv "MASC_CONFIG_DIR" config_root;
  Config_dir_resolver.reset ();
  ignore (Coord.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      ignore (Coord.reset config);
      Reg.clear ();
      KR.reset_test_state base;
      restore_env "MASC_CONFIG_DIR" original_config_dir;
      Config_dir_resolver.reset ();
      rm_rf base)
    (fun () -> f config)

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

let test_due_auto_recoverable_paused_keeper_starts_sweep () =
  with_temp_masc_dir ~keeper_names:[ "auto-due" ] (fun config ->
    let now = Unix.time () in
    write_meta_exn config
      (make_meta
         ~paused:true
         ~auto_resume_after_sec:60.0
         ~updated_at:(iso_of_unix (now -. 120.0))
         "auto-due");
    let stats =
      KR.{ scanned = 0; started = 0; stale = 0; recovering = 0 }
    in
    check bool "paused keeper is not bootable yet" false
      (List.mem "auto-due" (KR.bootable_keeper_names config));
    check (list string) "paused keeper is auto-recoverable"
      [ "auto-due" ]
      (KR.auto_recoverable_paused_keeper_names ~now config);
    check bool "due auto-recoverable pause starts supervisor sweep" true
      (KR.should_start_supervisor_sweep ~config ~stats))

let test_operator_paused_only_does_not_start_sweep () =
  with_temp_masc_dir ~keeper_names:[ "manual-only" ] (fun config ->
    let now = Unix.time () in
    write_meta_exn config
      (make_meta
         ~paused:true
         ~updated_at:(iso_of_unix (now -. 7200.0))
         "manual-only");
    let stats =
      KR.{ scanned = 0; started = 0; stale = 0; recovering = 0 }
    in
    check bool "operator-paused keeper is not bootable" false
      (List.mem "manual-only" (KR.bootable_keeper_names config));
    check (list string) "operator pause is not auto-recoverable" []
      (KR.auto_recoverable_paused_keeper_names ~now config);
    check bool "operator pause alone does not start sweep" false
      (KR.should_start_supervisor_sweep ~config ~stats))

let () =
  run "supervisor_start_predicate_10125" [
    "predicate", [
      test_case "disabled bootstrap + disk keeper → true (regression fix)" `Quick
        test_disabled_bootstrap_with_disk_keepers_starts_sweep;
      test_case "stats.started > 0 even when enabled = false → true" `Quick
        test_started_gt_zero_starts_sweep_without_enabled;
      test_case "predicate is total on defaulted stats (no raise)" `Quick
        test_predicate_total_on_defaulted_stats;
      test_case "due auto-recoverable paused keeper starts sweep" `Quick
        test_due_auto_recoverable_paused_keeper_starts_sweep;
      test_case "operator-paused keeper alone does not start sweep" `Quick
        test_operator_paused_only_does_not_start_sweep;
    ];
  ]
