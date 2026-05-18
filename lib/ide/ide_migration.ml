(** RFC-0128 §5 Phase 3 — flat-file purge migration. *)

open Ide_annotation_types

type migration_report =
  { annotations_total : int
  ; annotations_to_by_url : int
  ; annotations_to_orphan : int
  ; regions_total : int
  ; regions_to_by_url : int
  ; regions_to_orphan : int
  }

let zero_report =
  { annotations_total = 0
  ; annotations_to_by_url = 0
  ; annotations_to_orphan = 0
  ; regions_total = 0
  ; regions_to_by_url = 0
  ; regions_to_orphan = 0
  }
;;

(* Resolve a record's [file_path] to its target partition using the
   exact same lookup chain as the keeper write path
   ([Keeper_exec_fs.resolve_partition_for_write]). Centralising the
   logic here keeps PR-1c and PR-3 in lock-step — a divergence would
   route post-cut-over writes and pre-cut-over backlogged records to
   different buckets. *)
let resolve_partition ~base_path ~file_path =
  let abs =
    if Filename.is_relative file_path
    then Filename.concat base_path file_path
    else file_path
  in
  match Repo_store.find_repo_by_path_prefix ~base_path abs with
  | None -> Ide_paths.Orphan
  | Some (repo, _rel) ->
    let url = String.trim repo.Repo_manager_types.url in
    if url = ""
    then Ide_paths.Orphan
    else
      match Ide_paths.canonical_url_of_remote url with
      | None -> Ide_paths.Orphan
      | Some slug -> Ide_paths.By_url slug
;;

let rec ensure_dir path =
  if path = "" || path = "/" || (Sys.file_exists path && Sys.is_directory path)
  then ()
  else (
    ensure_dir (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let legacy_annotations_path ~base_path =
  Filename.concat
    (Ide_paths.partition_store_dir ~base_dir:base_path Ide_paths.Legacy)
    "annotations.jsonl"
;;

let legacy_regions_path ~base_path =
  Filename.concat
    (Ide_paths.partition_store_dir ~base_dir:base_path Ide_paths.Legacy)
    "regions.jsonl"
;;

(* Tombstones live in annotations.jsonl alongside live records and must
   travel with their original record so [Ide_annotations.list]'s
   tombstone filter keeps working post-migration. Returns the original
   JSON unchanged so the migrated file is byte-for-byte equivalent to
   what a live keeper would have written. *)
let migrate_annotation_line ~base_path ~dry_run json report =
  let report = { report with annotations_total = report.annotations_total + 1 } in
  let pick_file_path () =
    match annotation_of_json json with
    | Ok (a : annotation) -> Some a.file_path
    | Error _ ->
      (* Tombstone or malformed line — fall back to the raw "file_path"
         field if present. Tombstones don't have one, in which case
         we route to Orphan so the row is not lost. *)
      (match json with
       | `Assoc fields ->
         (match List.assoc_opt "file_path" fields with
          | Some (`String s) when s <> "" -> Some s
          | _ -> None)
       | _ -> None)
  in
  let partition =
    match pick_file_path () with
    | Some fp -> resolve_partition ~base_path ~file_path:fp
    | None -> Ide_paths.Orphan
  in
  if not dry_run then begin
    let dir = Ide_paths.partition_store_dir ~base_dir:base_path partition in
    ensure_dir dir;
    Fs_compat.append_jsonl (Filename.concat dir "annotations.jsonl") json
  end;
  match partition with
  | Ide_paths.By_url _ ->
    { report with annotations_to_by_url = report.annotations_to_by_url + 1 }
  | Ide_paths.Orphan ->
    { report with annotations_to_orphan = report.annotations_to_orphan + 1 }
  | Ide_paths.Legacy ->
    (* Unreachable — [resolve_partition] never returns Legacy. *)
    report
;;

let migrate_region_line ~base_path ~dry_run json report =
  let report = { report with regions_total = report.regions_total + 1 } in
  let file_path =
    match region_of_json json with
    | Ok (r : code_region) -> Some r.file_path
    | Error _ ->
      (match json with
       | `Assoc fields ->
         (match List.assoc_opt "file_path" fields with
          | Some (`String s) when s <> "" -> Some s
          | _ -> None)
       | _ -> None)
  in
  let partition =
    match file_path with
    | Some fp -> resolve_partition ~base_path ~file_path:fp
    | None -> Ide_paths.Orphan
  in
  if not dry_run then begin
    let dir = Ide_paths.partition_store_dir ~base_dir:base_path partition in
    ensure_dir dir;
    Fs_compat.append_jsonl (Filename.concat dir "regions.jsonl") json
  end;
  match partition with
  | Ide_paths.By_url _ ->
    { report with regions_to_by_url = report.regions_to_by_url + 1 }
  | Ide_paths.Orphan ->
    { report with regions_to_orphan = report.regions_to_orphan + 1 }
  | Ide_paths.Legacy -> report
;;

let migrate_file ~path ~per_line report =
  if not (Sys.file_exists path) then report
  else
    Fs_compat.fold_jsonl_lines
      ~init:report
      ~f:(fun acc ~line_no:_ json -> per_line json acc)
      path
;;

let migrate_flat_to_partitioned
      ~base_path
      ?(dry_run = false)
      ?(delete_legacy_after = false)
      ()
  =
  let report = zero_report in
  let report =
    migrate_file
      ~path:(legacy_annotations_path ~base_path)
      ~per_line:(migrate_annotation_line ~base_path ~dry_run)
      report
  in
  let report =
    migrate_file
      ~path:(legacy_regions_path ~base_path)
      ~per_line:(migrate_region_line ~base_path ~dry_run)
      report
  in
  if delete_legacy_after && not dry_run then begin
    let try_remove path = try Sys.remove path with Sys_error _ -> () in
    try_remove (legacy_annotations_path ~base_path);
    try_remove (legacy_regions_path ~base_path)
  end;
  report
;;
