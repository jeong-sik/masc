(* #39331 milestone B: the kept vision store has no size cap by design --
   [#38634] P1-1 puts checkpoint- and upload-referenced handles at the
   [<keeper>.vision] root with pruning off, because a size-based eviction
   there deletes handles the durable record still points at. The growth the
   #39331 measurement blamed on this store is un-referenced kept files: an
   eviction that stored an image the model never got to read, or a kept
   image whose referencing turns are gone.

   This module is the reference-based sweep for that root. It follows the
   two-pass candidate pattern of [Tool_blob_maintenance] (lib/tool_blob_store/
   tool_blob_maintenance.ml): a complete reference scan produces the
   candidates, the candidates are persisted, and only handles that sat in
   both the previous and the current complete snapshot are deleted. A handle
   that stops being referenced but comes back within one sweep interval
   (for example a turn restored from an older checkpoint) is therefore kept.

   The scan itself is [Vision_artifact_reference.is_referenced] over the
   store's own durable-consumer list. Unknowns are not candidates: any
   [Error] from the predicate aborts the sweep before anything is deleted,
   because an unknown is exactly where a live handle would be missed. The
   previous-run contract must stay alive for a sweep to delete: a missing
   snapshot means an earlier sweep never completed its bookkeeping, and
   deleting without it would not be the second observation the contract
   requires. Symlinks surface through the same abort path, so a store that
   cannot be scanned fully is never swept. *)

let ( let* ) = Result.bind

module Handle_set = Set.Make (String)
module String_map = Map.Make (String)

type error =
  | Invalid_store_root of { dir : string; detail : string }
  | Reference_scan_failed of
      { handle : string
      ; detail : string
      }
  | Snapshot_read_failed of { detail : string }
  | Snapshot_write_failed of { detail : string }
  | Delete_failed of
      { handle : string
      ; detail : string
      }

let error_to_string = function
  | Invalid_store_root { dir; detail } ->
    Printf.sprintf "kept vision store root rejected at %s: %s" dir detail
  | Reference_scan_failed { handle; detail } ->
    Printf.sprintf "reference scan failed for handle %s: %s" handle detail
  | Snapshot_read_failed { detail } ->
    Printf.sprintf "candidate snapshot read failed: %s" detail
  | Snapshot_write_failed { detail } ->
    Printf.sprintf "candidate snapshot write failed: %s" detail
  | Delete_failed { handle; detail } ->
    Printf.sprintf "delete failed for handle %s: %s" handle detail
;;

let candidate_snapshot_filename = "kept-candidates.json"

let candidate_snapshot_path ~dir = Filename.concat dir candidate_snapshot_filename

type report =
  { scanned : int
    (* Kept files this sweep observed at the root (canonical names). *)
  ; live : int
    (* Handles the scan still finds referenced. *)
  ; candidates_recorded : int
    (* Un-referenced handles this sweep recorded for the next sweep. *)
  ; deleted : int
    (* Handles deleted this sweep: in the previous candidates too. *)
  ; reclaimed_bytes : Int64.t
  ; remaining_count : int
  ; remaining_bytes : Int64.t
  }
;;

(* Mirrors Vision_artifact_store.is_canonical, which is not exported. A kept
   entry is a 64-char lowercase-hex name; anything else at the root is not
   this store's file and the sweep leaves it alone. *)
let is_canonical_name name =
  String.length name = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       name
;;

exception Sweep_stop of error

(* Root entries only: the sweep's store is the [<keeper>.vision] root.
   [frames/] is not in scope -- it has its own size-capped retention
   (#38634) -- and anything non-canonical is left exactly where it is. The
   byte size comes back so the report can say what a sweep would reclaim. *)
let kept_entries ~dir =
  let names = Sys.readdir dir in
  let items =
    Array.fold_left
      (fun acc name ->
         if not (is_canonical_name name)
         then acc
         else
           let path = Filename.concat dir name in
           match Unix.lstat path with
           | exception Unix.Unix_error (Unix.ENOENT, _, _) -> acc
           | exception Unix.Unix_error (err, fn, arg) ->
             raise
               (Sweep_stop
                  (Reference_scan_failed
                     { handle = name
                     ; detail =
                         Printf.sprintf
                           "%s(%s): %s"
                           fn
                           arg
                           (Unix.error_message err)
                     }))
           | stat ->
             (match stat.Unix.st_kind with
              | Unix.S_REG -> (name, Int64.of_int stat.Unix.st_size) :: acc
              | Unix.S_LNK ->
                raise
                  (Sweep_stop
                     (Reference_scan_failed
                        { handle = name
                        ; detail =
                            Printf.sprintf
                              "symlink at kept root: %s"
                              path
                        }))
              | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
              | Unix.S_SOCK -> acc))
      []
      names
  in
  List.sort (fun (a, _) (b, _) -> String.compare a b) items
;;

let decode_snapshot raw =
  match Yojson.Safe.from_string raw with
  | exception _ -> Error "snapshot is not JSON"
  | `List values ->
    let rec collect acc = function
      | [] -> Ok acc
      | `String handle :: rest when is_canonical_name handle ->
        collect (Handle_set.add handle acc) rest
      | _ :: _ -> Error "snapshot carries a non-handle entry"
    in
    collect Handle_set.empty values
  | _ -> Error "snapshot is not a JSON array"
;;

let load_previous_candidates ~dir =
  let path = candidate_snapshot_path ~dir in
  match Fs_compat.load_owned_regular_file ~ownership_root:dir path with
  | Ok None -> Ok None
  | Ok (Some content) ->
    (match decode_snapshot content with
     | Ok handles -> Ok (Some handles)
     | Error reason -> Error (Snapshot_read_failed { detail = reason }))
  | Error rejection ->
    Error
      (Snapshot_read_failed
         { detail =
             Fs_compat.owned_regular_file_read_error_to_string rejection
         })
;;

let save_candidates ~dir handles =
  let payload =
    `List
      (Handle_set.elements handles |> List.map (fun handle -> `String handle))
    |> Yojson.Safe.to_string
  in
  let path = candidate_snapshot_path ~dir in
  match Fs_compat.save_file_atomic path payload with
  | Ok () -> Ok ()
  | Error detail -> Error (Snapshot_write_failed { detail })
;;

let scan_live ~masc_dir entries =
  let rec loop live = function
    | [] -> Ok live
    | (handle, _) :: rest -> (
      match Vision_artifact_reference.is_referenced ~masc_dir ~handle with
      | Ok true -> loop (Handle_set.add handle live) rest
      | Ok false -> loop live rest
      | Error error ->
        Error
          (Reference_scan_failed
             { handle
             ; detail = Vision_artifact_reference.error_to_string error
             }))
  in
  loop Handle_set.empty entries
;;

let delete_candidates ~dir candidates sizes =
  let rec loop deleted reclaimed = function
    | [] -> Ok (deleted, reclaimed)
    | handle :: rest -> (
      let path = Filename.concat dir handle in
      match
        try
          Unix.unlink path;
          Ok ()
        with
        | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
        (* raced with a concurrent store: nothing to delete *)
        | Unix.Unix_error (err, fn, arg) ->
          Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err))
      with
      | Error detail -> Error (Delete_failed { handle; detail })
      | Ok () ->
        let size =
          match String_map.find_opt handle sizes with
          | Some bytes -> bytes
          | None -> 0L
        in
        loop (deleted + 1) (Int64.add reclaimed size) rest)
  in
  loop 0 0L (Handle_set.elements candidates)
;;

let empty_report =
  { scanned = 0
  ; live = 0
  ; candidates_recorded = 0
  ; deleted = 0
  ; reclaimed_bytes = 0L
  ; remaining_count = 0
  ; remaining_bytes = 0L
  }
;;

let store_root_is_directory dir =
  match Unix.lstat dir with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | exception Unix.Unix_error (error, _, _) ->
    Error (Invalid_store_root { dir; detail = Unix.error_message error })
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_DIR -> Ok true
     | Unix.S_LNK ->
       Error (Invalid_store_root { dir; detail = "symlinked store root" })
     | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
       Error (Invalid_store_root { dir; detail = "store root is not a directory" }))
;;

let run ~masc_dir ~dir =
  let* present = store_root_is_directory dir in
  if not present then Ok empty_report else
    try
      let entries = kept_entries ~dir in
      let sizes =
        List.fold_left
          (fun acc (handle, size) -> String_map.add handle size acc)
          String_map.empty
          entries
      in
      let scanned = List.length entries in
      let* live = scan_live ~masc_dir entries in
      let candidates =
        List.fold_left
          (fun acc (handle, _) ->
             if Handle_set.mem handle live
             then acc
             else Handle_set.add handle acc)
          Handle_set.empty
          entries
      in
      let* previous_candidates = load_previous_candidates ~dir in
      let* () = save_candidates ~dir candidates in
      let deletable =
        match previous_candidates with
        | None -> Handle_set.empty
        | Some previous -> Handle_set.inter previous candidates
      in
      let* deleted, reclaimed = delete_candidates ~dir deletable sizes in
      let remaining =
        List.filter
          (fun (handle, _) -> not (Handle_set.mem handle deletable))
          entries
      in
      let remaining_bytes =
        List.fold_left (fun acc (_, size) -> Int64.add acc size) 0L remaining
      in
      Ok
        { scanned
        ; live = Handle_set.cardinal live
        ; candidates_recorded = Handle_set.cardinal candidates
        ; deleted
        ; reclaimed_bytes = reclaimed
        ; remaining_count = List.length remaining
        ; remaining_bytes
        }
    with
    | Sweep_stop error -> Error error
;;
