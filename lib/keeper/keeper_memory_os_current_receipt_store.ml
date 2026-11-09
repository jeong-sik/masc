open Result.Syntax
module Receipt_selection = Keeper_memory_os_receipt_selection
open Keeper_memory_os_current_types
open Keeper_memory_os_current_layout
open Keeper_memory_os_current_range_codec

(* Same regular file with the same size and timestamps. An atomic replace
   gives the path a new inode, and every change to a file's bytes or metadata
   sets its ctime, which user space cannot set back. *)
let same_file_identity a b =
  a.Unix.st_kind = Unix.S_REG && b.Unix.st_kind = Unix.S_REG
  && a.Unix.st_dev = b.Unix.st_dev && a.Unix.st_ino = b.Unix.st_ino
  && a.Unix.st_size = b.Unix.st_size && a.Unix.st_mtime = b.Unix.st_mtime
  && a.Unix.st_ctime = b.Unix.st_ctime

module Path_map = Map.Make (String)

let rejected_marker = ".rejected-"

let is_digits text = text <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) text

(* [unused_rejected_path] writes [<base>.rejected-<epoch>], then
   [<base>.rejected-<epoch>-<n>] while that name is taken. *)
let rejected_base name =
  let marker = String.length rejected_marker in
  let rec find from =
    if from + marker > String.length name then None
    else if String.sub name from marker = rejected_marker then (
      let rest = String.sub name (from + marker) (String.length name - from - marker) in
      let stamped =
        match String.index_opt rest '-' with
        | None -> is_digits rest
        | Some dash ->
          is_digits (String.sub rest 0 dash)
          && is_digits (String.sub rest (dash + 1) (String.length rest - dash - 1))
      in
      if stamped && from > 0 then Some (String.sub name 0 from) else find (from + 1))
    else find (from + 1)
  in
  find 0

(* Moved up from beside the snapshot quarantine: the receipt reconcile below
   quarantines undecodable entries the same way. *)
let unused_rejected_path ~snapshot_path ~now =
  let base = Printf.sprintf "%s%s%.0f" snapshot_path rejected_marker now in
  if not (Fs_compat.file_exists base)
  then base
  else (
    let rec next attempt =
      let candidate = Printf.sprintf "%s-%d" base attempt in
      if Fs_compat.file_exists candidate then next (attempt + 1) else candidate
    in
    next 2)
;;

(* A reconcile against the snapshot at [fixed_revision] whose bytes hash to
   [fixed_snapshot_sha256] returned the cached receipts unchanged. *)
type receipt_fixed_point =
  { fixed_revision : int
  ; fixed_snapshot_sha256 : string
  }

(* [receipts] is the result of [read_durable_range_receipts] for the file
   [receipt_identity] describes: the same decode and the same validation. *)
type durable_range_receipt_cache_entry =
  { receipt_identity : Unix.stats
  ; receipts : durable_range_receipt list
  ; fixed_point : receipt_fixed_point option
  }

(* Keyed by sidecar path. Entries are immutable and replaced by compare-and-set,
   so a reader on any domain sees a whole entry or none. *)
let durable_range_receipt_cache : durable_range_receipt_cache_entry Path_map.t Atomic.t =
  Atomic.make Path_map.empty

let rec update_durable_range_receipt_cache path f =
  let before = Atomic.get durable_range_receipt_cache in
  let after = Path_map.update path f before in
  if not (Atomic.compare_and_set durable_range_receipt_cache before after)
  then update_durable_range_receipt_cache path f
;;

let forget_durable_range_receipts path =
  update_durable_range_receipt_cache path
    (fun (_ : durable_range_receipt_cache_entry option) -> None)
;;

(* File timestamps are no coarser than one second on the filesystems masc runs
   on (HFS+ stores whole seconds; APFS and ext4 store nanoseconds at kernel
   clock-tick resolution). A file whose ctime is further than this behind the
   clock therefore cannot change again without its ctime changing. A file
   changed more recently is decoded on every read: a second change within the
   same timestamp tick can keep every field [same_file_identity] compares. *)
let receipt_identity_settle_seconds = 1.0

let inspect_receipt_file path =
  match Unix.lstat path with
  | stats -> Some stats
  | exception Unix.Unix_error ((_ : Unix.error), (_ : string), (_ : string)) -> None
;;

type durable_range_receipt_read =
  | Cached_receipts of durable_range_receipt_cache_entry
  | Uncached_receipts of durable_range_receipt list * skipped_range_receipt list

(* A cached entry answers only while the file still has the identity it had
   when it was decoded. An entry is published only when the file kept one
   identity across the decode and its ctime was already settled when the read
   began, so every later change to the file gives it an identity the entry
   does not match. A missing, non-regular, recently changed, or concurrently
   changed file is decoded on every read, as is a file with skipped entries:
   only clean files are cached, so a cache hit proves there was nothing to
   skip and the consume path rewrites a healing file on its next pass. *)
let read_durable_range_receipts_cached ~keepers_dir ~keeper_id =
  let path = durable_range_receipt_path ~keepers_dir ~keeper_id in
  let started = Unix.gettimeofday () in
  let before = inspect_receipt_file path in
  match before, Path_map.find_opt path (Atomic.get durable_range_receipt_cache) with
  | Some current, Some cached when same_file_identity cached.receipt_identity current ->
    Ok (Cached_receipts cached)
  | (Some _ | None), (Some _ | None) ->
    forget_durable_range_receipts path;
    let* receipts, skipped = read_durable_range_receipts ~keepers_dir ~keeper_id in
    (match before, inspect_receipt_file path with
     | Some before, Some after
       when same_file_identity before after
            && started -. before.Unix.st_ctime > receipt_identity_settle_seconds
            && skipped = [] ->
       let entry = { receipt_identity = after; receipts; fixed_point = None } in
       update_durable_range_receipt_cache path
         (fun (_ : durable_range_receipt_cache_entry option) -> Some entry);
       Ok (Cached_receipts entry)
     | (Some _ | None), (Some _ | None) -> Ok (Uncached_receipts (receipts, skipped)))
;;

let mark_receipt_fixed_point ~keepers_dir ~keeper_id entry fixed_point =
  update_durable_range_receipt_cache
    (durable_range_receipt_path ~keepers_dir ~keeper_id)
    (function
      | Some current when current == entry -> Some { entry with fixed_point = Some fixed_point }
      | (Some _ | None) as unchanged -> unchanged)
;;

(* The replaced file already has a new identity; dropping the entry also covers
   a write that reports failure after the replace. *)
let write_durable_range_receipts ~keepers_dir ~keeper_id receipts =
  let path = durable_range_receipt_path ~keepers_dir ~keeper_id in
  let written =
    Fs_compat.save_file_atomic_strict path
      (Yojson.Safe.to_string (durable_range_receipts_to_json receipts))
  in
  forget_durable_range_receipts path;
  written
  |> Result.map_error (fun message ->
    Printf.sprintf
      "durable Librarian range receipt write failed path=%s: %s"
      path
      message)
;;

let remove_durable_range_receipts ~keepers_dir ~keeper_id =
  let path = durable_range_receipt_path ~keepers_dir ~keeper_id in
  let removed =
    match Sys.remove path with
    | () -> Ok ()
    | exception Sys_error _ when not (Sys.file_exists path) -> Ok ()
    | exception exn -> (* cancel-guard-ok: Sys.remove performs no Eio operation, so Cancelled cannot originate in this body. *)
      Error
        (Printf.sprintf
           "durable Librarian range receipt removal failed path=%s: %s"
           path
           (Printexc.to_string exn))
  in
  forget_durable_range_receipts path;
  removed
;;

(* Move receipt entries aside before the ledger is rewritten without them:
   entries this binary cannot decode, and receipts the snapshot does not
   prove. Recovering by destroying the only copy of the rejected state is
   not recovery, so a sidecar write failure keeps the entries in place and
   fails the pass. Once the sidecar can be written again (a full disk has
   space), the next pass quarantines them and proceeds. Nothing reads a
   sidecar back. *)
let quarantine_skipped_range_receipts ~keepers_dir ~keeper_id ~skipped =
  match skipped with
  | [] -> Ok ()
  | _ :: _ ->
    let receipt_path = durable_range_receipt_path ~keepers_dir ~keeper_id in
    let rejected_path =
      unused_rejected_path ~snapshot_path:receipt_path ~now:(Unix.gettimeofday ())
    in
    let entry_to_json { index; reason; entry } =
      `Assoc [ "index", `Int index; "reason", `String reason; "entry", entry ]
    in
    let payload =
      Yojson.Safe.to_string (`Assoc [ "receipts", `List (List.map entry_to_json skipped) ])
    in
    (match Fs_compat.save_file_atomic_strict rejected_path payload with
     | Ok () ->
       Log.Keeper.warn
         ~keeper_name:keeper_id
         "durable Librarian range receipts quarantined path=%s rejected_path=%s skipped=%s"
         receipt_path
         rejected_path
         (String.concat ";"
            (List.map (fun skipped -> Printf.sprintf "%d:%s" skipped.index skipped.reason) skipped));
       Ok ()
     | Error message ->
       Error
         (Printf.sprintf
            "durable Librarian range receipt quarantine failed path=%s rejected_path=%s: %s"
            receipt_path
            rejected_path
            message))
;;

let sha256 content = Agent_core_sha256.(digest_string content |> to_hex)

let receipt_range_id = function
  | Prepared { range_id; _ } | Committed { range_id; _ } -> range_id
;;

let receipt_holes = function
  | Atom_range range -> range.unread_messages
  | Official_range range -> range.unread_messages
  | Explicit_candidate _ | Explicit_candidate_with_recall _ -> []
;;

let archive_verified_holes ~keepers_dir ~keeper_id receipts =
  let* holes = List.fold_left (fun merged -> function
    | Committed {range_id;_} ->
      let* merged = merged in Keeper_librarian_unread.merge merged (receipt_holes range_id)
    | Prepared _ -> merged) (Ok []) receipts in
  Keeper_librarian_unread_ledger.archive ~keepers_dir ~keeper_id holes
;;

let upsert_durable_range_receipt receipts receipt =
  let key = Receipt_selection.range_key (receipt_range_id receipt) in
  receipt :: List.filter (fun prior ->
    Receipt_selection.range_key (receipt_range_id prior) <> key
    || (match receipt, prior with
        | Prepared _, Committed _ -> true
        | Prepared _, Prepared _ | Committed _, _ -> false)) receipts
;;

let sync_matching_prepared_snapshot ~keepers_dir ~keeper_id ~snapshot receipts =
  let needs_sync = List.exists (function
    | Prepared {snapshot_revision; snapshot_sha256; _} ->
      (match snapshot with
       | Some (current, digest) -> current.revision = snapshot_revision
           && String.equal (Lazy.force digest) snapshot_sha256
       | None -> false)
    | Committed _ -> false) receipts in
  if not needs_sync then Ok ()
  else Fs_compat.sync_file_and_parent_strict
    (path_for_keepers_dir ~keepers_dir ~keeper_id)
    |> Result.map_error (fun detail ->
      "prepared Memory snapshot durability is unconfirmed; stores preserved: " ^ detail)
;;

let reconcile_durable_range_receipts
      ~keepers_dir
      ~keeper_id
      ~snapshot
  =
  (* The snapshot is hashed at most once per pass, and only when a receipt or
     the cached fixed point names its revision. *)
  let snapshot =
    Option.map (fun (current, content) -> current, lazy (sha256 content)) snapshot
  in
  let* read = read_durable_range_receipts_cached ~keepers_dir ~keeper_id in
  let receipts, skipped, cached =
    match read with
    | Cached_receipts entry -> entry.receipts, [], Some entry
    | Uncached_receipts (receipts, skipped) -> receipts, skipped, None
  in
  (* A reconcile that returned the receipts unchanged at revision R with bytes S
     kept every receipt: each was committed, their keys were distinct, and each
     named a revision below R, or R with S. The snapshot at R with S is the
     same input. A snapshot above R keeps every receipt through the
     higher-revision rule in [Receipt_selection.select], so the result is
     unchanged again. A missing snapshot, a lower revision, or R with other
     bytes runs the full reconcile. *)
  let* () = sync_matching_prepared_snapshot ~keepers_dir ~keeper_id ~snapshot receipts in
  let covered =
    match cached, snapshot with
    | Some { fixed_point = Some fixed; _ }, Some (current, digest) ->
      current.revision > fixed.fixed_revision
      || (Int.equal current.revision fixed.fixed_revision
          && String.equal (Lazy.force digest) fixed.fixed_snapshot_sha256)
    | Some { fixed_point = Some _; _ }, None
    | Some { fixed_point = None; _ }, (Some _ | None)
    | None, (Some _ | None) -> false
  in
  if covered then
    let+ _ = archive_verified_holes ~keepers_dir ~keeper_id receipts in receipts
  else
    let selection =
      Receipt_selection.select
        ~snapshot:(Option.map (fun (current, digest) -> current.revision, digest) snapshot)
        ~had_skipped_entries:(skipped <> []) receipts
    in
    (* Keep every verified source for archival before applying the deduplicated
       decision: a redundant scope can still carry distinct unread evidence. *)
    let* _ = archive_verified_holes ~keepers_dir ~keeper_id
      selection.Receipt_selection.all_verified_for_archive in
    (* Exact-range proof exclusion is distinct from coarse-key retention. Encode
       unproven entries only after the verified unread evidence is durable. *)
    let unproven =
      List.map (fun (index, receipt) ->
          { index
          ; reason = "receipt lacks a matching Memory snapshot proof"
          ; entry = durable_range_receipt_to_json receipt
          }) selection.Receipt_selection.unproven
    in
    let* () = quarantine_skipped_range_receipts ~keepers_dir ~keeper_id ~skipped:unproven in
    (* Both quarantines precede removal/replacement, preserving every rejected
       byte even if the next write fails. Raw decoder positions stay separate. *)
    let* () = quarantine_skipped_range_receipts ~keepers_dir ~keeper_id ~skipped in
    match selection.Receipt_selection.decision with
    | Receipt_selection.Keep reconciled ->
      (match cached, snapshot with
       | Some entry, Some (current, digest) ->
         mark_receipt_fixed_point ~keepers_dir ~keeper_id entry
           { fixed_revision = current.revision; fixed_snapshot_sha256 = Lazy.force digest }
       | Some _, None | None, (Some _ | None) -> ());
      Ok reconciled
    | Receipt_selection.Remove ->
      let+ () = remove_durable_range_receipts ~keepers_dir ~keeper_id in []
    | Receipt_selection.Rewrite reconciled ->
      let+ () = write_durable_range_receipts ~keepers_dir ~keeper_id reconciled in
      reconciled
;;

let keeper_id_of_filename filename = Filename.chop_suffix_opt ~suffix filename
;;

let list_keeper_ids_for_keepers_dir ~keepers_dir =
  if not (Sys.file_exists keepers_dir && Sys.is_directory keepers_dir)
  then []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter_map keeper_id_of_filename
    |> List.sort String.compare
;;

(* The first publication can be interrupted before its snapshot exists. Keep
   this inventory separate from snapshot-only consumers such as the dashboard. *)
let rec missing_directory_or_broken_ancestor path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    let parent = Filename.dirname path in
    if String.equal path parent then Error (path ^ ": directory ancestry is absent")
    else missing_directory_or_broken_ancestor parent
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
    Error (path ^ ": " ^ Printexc.to_string exn)
  | _ ->
    (match Unix.stat path with
     | stat when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
     | _ -> Error (path ^ ": not a directory")
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
       Error (path ^ ": " ^ Printexc.to_string exn))
;;

let list_preflight_keeper_ids ~keepers_dir =
  try
    let stat = Unix.stat keepers_dir in
    if stat.Unix.st_kind <> Unix.S_DIR then
      Error (keepers_dir ^ ": not a directory")
    else
      Sys.readdir keepers_dir
      |> Array.to_list
      |> List.filter_map (fun filename ->
           match Filename.chop_suffix_opt ~suffix filename with
           | Some _ as id -> id
           | None ->
             (match Filename.chop_suffix_opt ~suffix:publication_receipt_suffix filename with
              | Some _ as id -> id
              | None ->
                Filename.chop_suffix_opt ~suffix:retraction_plan_receipt_suffix filename))
      |> List.sort_uniq String.compare
      |> fun ids -> Ok ids
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    (match Unix.lstat keepers_dir with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
       let+ () = missing_directory_or_broken_ancestor (Filename.dirname keepers_dir) in []
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
       Error (keepers_dir ^ ": " ^ Printexc.to_string exn)
     | _ -> Error (keepers_dir ^ ": directory target is absent"))
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Unix.Unix_error _ | Sys_error _) as exn ->
    Error (keepers_dir ^ ": " ^ Printexc.to_string exn)
;;

let list_durable_range_receipt_keeper_ids ~keepers_dir =
  if not (Sys.file_exists keepers_dir && Sys.is_directory keepers_dir)
  then []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter_map (Filename.chop_suffix_opt ~suffix:durable_range_receipt_suffix)
    |> List.sort String.compare
;;
