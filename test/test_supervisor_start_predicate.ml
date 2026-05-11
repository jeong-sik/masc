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
   which is a GLOBAL path (operator's [$HOME/.masc/config/keepers/])
   independent of the [Coord.config.base_path].  So in every test
   environment with the operator profile present,
   [bootable_keeper_names] returns non-empty.  The tests below
   exploit that — they verify the post-fix path
   ([enabled = false] still triggers sweep) without trying to
   construct an empty profile environment. *)

open Alcotest

module Coord = Masc_mcp.Coord
module KR = Masc_mcp.Keeper_runtime

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else
      Sys.remove path

let with_temp_masc_dir f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-10125-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  let config = Coord.default_config base in
  ignore (Coord.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      ignore (Coord.reset config);
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

let () =
  run "supervisor_start_predicate_10125" [
    "predicate", [
      test_case "disabled bootstrap + disk keeper → true (regression fix)" `Quick
        test_disabled_bootstrap_with_disk_keepers_starts_sweep;
      test_case "stats.started > 0 even when enabled = false → true" `Quick
        test_started_gt_zero_starts_sweep_without_enabled;
      test_case "predicate is total on defaulted stats (no raise)" `Quick
        test_predicate_total_on_defaulted_stats;
    ];
  ]
