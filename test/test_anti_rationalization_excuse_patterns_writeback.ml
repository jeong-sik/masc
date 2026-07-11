(** [excuse_patterns_writeback] — pin the disk write-back contract for
    [load_excuse_patterns].

    Before this fix the migration from legacy English-only patterns to
    the current built-in defaults happened in memory only.  Every boot
    re-read the same stale on-disk file, re-ran the migration, and
    re-emitted the INFO log line.  The dashboard administrator surface
    that lets operators see the active patterns ([GET
    /api/v1/dashboard/config/excuse-patterns]) returned the migrated
    list while the file on disk continued to advertise the legacy
    snapshot — a quiet divergence between operator-visible state and
    the persisted source of truth.

    This test fixes that contract: after one [load_excuse_patterns]
    call the on-disk file must reflect the migrated list, so a second
    boot (or a fresh process) loads the current defaults directly with
    no migration step at all. *)

open Alcotest

module A = Masc.Task.Anti_rationalization

let legacy_english_only_json =
  {|[
  ["pre-existing", "claiming the problem already existed"],
  ["out of scope", "declaring work out of scope"],
  ["beyond the scope", "declaring work beyond scope"],
  ["will do later", "deferring work to later"],
  ["will fix later", "deferring fix to later"],
  ["will address later", "deferring to later"],
  ["follow-up", "deferring to a follow-up"],
  ["follow up", "deferring to a follow-up"],
  ["works on my end", "unverifiable claim"],
  ["works on my machine", "unverifiable claim"],
  ["not reproducible", "dismissing without investigation"],
  ["not my responsibility", "responsibility deflection"],
  ["cannot reproduce", "dismissing without investigation"]
]|}

let write_legacy_config dir =
  let path = Filename.concat dir "excuse_patterns.json" in
  let oc = open_out path in
  output_string oc legacy_english_only_json;
  close_out oc;
  path

let isolated_config_dir tag =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "anti_rat_writeback_%s_%d_%.0f"
         tag (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  Unix.mkdir dir 0o700;
  dir

let count_entries_in_disk_file path =
  let json = Yojson.Safe.from_file path in
  match json with
  | `List items -> List.length items
  | _ ->
      failf "expected JSON array on disk, got %s"
        (Yojson.Safe.to_string json)

let test_writeback_after_migration () =
  let dir = isolated_config_dir "after-migration" in
  let path = write_legacy_config dir in
  Unix.putenv "MASC_CONFIG_DIR" dir;
  Config_dir_resolver.reset ();
  let in_memory = A.load_excuse_patterns () in
  let on_disk_after = count_entries_in_disk_file path in
  check int "in-memory pattern count matches migrated defaults"
    23 (List.length in_memory);
  check int
    "on-disk file is rewritten with the migrated pattern list \
     (next boot sees the current defaults directly, no migration)"
    23 on_disk_after

let test_no_writeback_when_not_legacy () =
  let dir = isolated_config_dir "no-migration" in
  let path = Filename.concat dir "excuse_patterns.json" in
  let custom =
    {|[
  ["operator-custom-marker", "custom rationalization phrase"]
]|}
  in
  let oc = open_out path in
  output_string oc custom;
  close_out oc;
  let mtime_before = (Unix.stat path).st_mtime in
  Unix.putenv "MASC_CONFIG_DIR" dir;
  Config_dir_resolver.reset ();
  A.reset_cache_for_tests ();
  let in_memory = A.load_excuse_patterns () in
  let mtime_after = (Unix.stat path).st_mtime in
  check int "custom single-entry config is loaded verbatim"
    1 (List.length in_memory);
  check (float 0.0)
    "on-disk mtime unchanged (no spurious write-back for non-legacy \
     configs)"
    mtime_before mtime_after

let () =
  Eio_main.run @@ fun _env ->
  run "anti_rationalization_excuse_patterns_writeback"
    [
      ( "migration-writeback",
        [
          test_case
            "legacy-only on-disk → write-back persists migrated defaults"
            `Quick test_writeback_after_migration;
          test_case
            "custom on-disk → no write-back, file mtime preserved" `Quick
            test_no_writeback_when_not_legacy;
        ] );
    ]
