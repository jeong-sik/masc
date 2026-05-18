(** [masc_ide_migrate] — CLI for RFC-0128 §5 Phase 3 purge migration.

    Walks [{base}/.masc-ide/annotations.jsonl] and
    [{base}/.masc-ide/regions.jsonl] and rewrites each record into the
    canonical-URL bucket resolved from its [file_path]. Wrapping for
    {!Masc_mcp.Ide_migration.migrate_flat_to_partitioned} so an
    operator can preview (--dry-run) and then commit (--commit
    [--delete-legacy]) the migration outside the server's lifetime.

    Default is [--dry-run] — destructive moves require [--commit]. *)

module Mig = Ide_migration

let usage =
  {|Usage: masc_ide_migrate --base-path PATH [OPTIONS]

Reads the Legacy flat .masc-ide stores under PATH and rewrites every
record into .masc-ide/by-url/<slug>/ (when a registered repository's
local_path is a prefix of the record's file_path) or
.masc-ide/_orphan/ (otherwise).

Required:
  --base-path PATH     project root (directory containing .masc/ and
                       .masc-ide/). Same value the masc-mcp server is
                       launched with via --base-path.

Modes (mutually exclusive — default is --dry-run):
  --dry-run            compute the partition split and print the
                       report. No files are written, Legacy is
                       untouched. Use this first.
  --commit             actually rewrite records into by-url/_orphan.
                       Legacy files are kept unless --delete-legacy
                       is also passed.
  --delete-legacy      (only with --commit) remove
                       .masc-ide/{annotations,regions}.jsonl after a
                       successful migration. The new partitions hold
                       a complete copy by then; deleting Legacy makes
                       subsequent merge_legacy reads a no-op.

  -h, --help           show this message and exit.

Exit codes:
  0  success — report printed (and, in --commit mode, records moved).
  1  invalid argument or IO failure.

The migration is idempotent: re-running on an already-migrated store
returns a zero-count report.
|}

let error msg =
  prerr_endline msg;
  exit 1
;;

type mode = Dry_run | Commit

type cli = {
  base_path : string;
  mode : mode;
  delete_legacy : bool;
}

let parse argv =
  let base_path = ref None in
  let mode = ref None in
  let delete_legacy = ref false in
  let set_mode m =
    match !mode with
    | None -> mode := Some m
    | Some _ -> error "specify only one of --dry-run / --commit"
  in
  let rec loop i =
    if i >= Array.length argv
    then ()
    else (
      let a = argv.(i) in
      match a with
      | "--base-path" ->
        if i + 1 >= Array.length argv then error "--base-path requires a value";
        base_path := Some argv.(i + 1);
        loop (i + 2)
      | "--dry-run" ->
        set_mode Dry_run;
        loop (i + 1)
      | "--commit" ->
        set_mode Commit;
        loop (i + 1)
      | "--delete-legacy" ->
        delete_legacy := true;
        loop (i + 1)
      | "-h" | "--help" ->
        print_string usage;
        exit 0
      | other -> error (Printf.sprintf "unknown argument: %s" other))
  in
  loop 1;
  let base_path =
    match !base_path with
    | Some p when String.trim p <> "" -> p
    | _ -> error "missing required --base-path"
  in
  if not (Sys.file_exists base_path) then
    error (Printf.sprintf "base path does not exist: %s" base_path);
  if not (Sys.is_directory base_path) then
    error (Printf.sprintf "base path is not a directory: %s" base_path);
  let mode = match !mode with Some m -> m | None -> Dry_run in
  let delete_legacy = !delete_legacy in
  if delete_legacy && mode = Dry_run then
    error "--delete-legacy requires --commit";
  { base_path; mode; delete_legacy }
;;

let print_report cli (report : Mig.migration_report) =
  let mode_label =
    match cli.mode with
    | Dry_run -> "DRY RUN (no files written)"
    | Commit ->
      if cli.delete_legacy
      then "COMMIT + delete legacy after"
      else "COMMIT (legacy retained)"
  in
  Printf.printf "RFC-0128 §5 Phase 3 — flat-file purge migration\n";
  Printf.printf "  base path: %s\n" cli.base_path;
  Printf.printf "  mode:      %s\n" mode_label;
  Printf.printf "\n";
  Printf.printf "  annotations:\n";
  Printf.printf "    total       %d\n" report.annotations_total;
  Printf.printf "    -> by-url   %d\n" report.annotations_to_by_url;
  Printf.printf "    -> _orphan  %d\n" report.annotations_to_orphan;
  Printf.printf "  regions:\n";
  Printf.printf "    total       %d\n" report.regions_total;
  Printf.printf "    -> by-url   %d\n" report.regions_to_by_url;
  Printf.printf "    -> _orphan  %d\n" report.regions_to_orphan;
  let orphan_total = report.annotations_to_orphan + report.regions_to_orphan in
  if orphan_total > 0 then begin
    Printf.printf "\n";
    Printf.printf
      "Note: %d record(s) routed to _orphan. Register the missing\n"
      orphan_total;
    Printf.printf
      "      repositories in .masc/config/repositories.toml (or fix the\n";
    Printf.printf
      "      URL field on existing entries) and re-run to reclaim them.\n"
  end
;;

let () =
  let cli =
    try parse Sys.argv with
    | Failure msg -> error msg
  in
  let dry_run =
    match cli.mode with
    | Dry_run -> true
    | Commit -> false
  in
  let report =
    Mig.migrate_flat_to_partitioned
      ~base_path:cli.base_path
      ~dry_run
      ~delete_legacy_after:cli.delete_legacy
      ()
  in
  print_report cli report
;;
