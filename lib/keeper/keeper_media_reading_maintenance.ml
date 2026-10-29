(* Two-pass reference sweep for stored media readings; the rules are in the
   .mli. The snapshot contract and the abort-before-delete on anything
   unreadable follow Multimodal.Vision_kept_maintenance; liveness comes from
   Tool_blob_maintenance's typed scan instead of a text search. *)

open Result.Syntax

module Name_set = Set.Make (String)
module String_map = Map.Make (String)

type error =
  | Invalid_store_root of
      { dir : string
      ; detail : string
      }
  | Record_read_failed of
      { name : string
      ; detail : string
      }
  | Snapshot_read_failed of { detail : string }
  | Snapshot_write_failed of { detail : string }
  | Delete_failed of
      { name : string
      ; detail : string
      }

let error_to_string = function
  | Invalid_store_root { dir; detail } ->
    Printf.sprintf "media reading store root rejected at %s: %s" dir detail
  | Record_read_failed { name; detail } ->
    Printf.sprintf "media reading record unreadable %s: %s" name detail
  | Snapshot_read_failed { detail } ->
    Printf.sprintf "media reading candidate snapshot read failed: %s" detail
  | Snapshot_write_failed { detail } ->
    Printf.sprintf "media reading candidate snapshot write failed: %s" detail
  | Delete_failed { name; detail } ->
    Printf.sprintf "delete failed for media reading %s: %s" name detail
;;

type report =
  { scanned : int
  ; live : int
  ; candidates_recorded : int
  ; deleted : int
  ; reclaimed_bytes : Int64.t
  ; remaining_count : int
  ; remaining_bytes : Int64.t
  }

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

let candidate_snapshot_filename = "reading-candidates.json"
let record_suffix = ".json"
let sha256_hex_length = 64

let is_lower_hex = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false
;;

(* Mirrors Keeper_media_reading.record_path: "<kind>-<sha>-<media>.json",
   where <media> is the already-sanitised media type segment. The digest is
   the attachment's, as its history [Stored] source names it. *)
let record_digest name =
  let strip_prefix prefix value =
    if String.starts_with ~prefix value
    then
      Some
        (String.sub value (String.length prefix) (String.length value - String.length prefix))
    else None
  in
  let after_kind =
    match strip_prefix "audio-" name with
    | Some rest -> Some rest
    | None -> strip_prefix "document-" name
  in
  match after_kind with
  | None -> None
  | Some rest ->
    if String.length rest > sha256_hex_length + 1 + String.length record_suffix
       && String.for_all is_lower_hex (String.sub rest 0 sha256_hex_length)
       && rest.[sha256_hex_length] = '-'
       && String.ends_with ~suffix:record_suffix rest
    then Some (String.sub rest 0 sha256_hex_length)
    else None
;;

let is_record_name name = Option.is_some (record_digest name)

exception Sweep_stop of error

let unix_detail err fn arg = Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err)

(* Regular record files only. A symlink stops the sweep: the record it points
   at could be anywhere, and deleting through it is not this sweep's call. *)
let record_entries ~dir =
  Sys.readdir dir
  |> Array.fold_left
       (fun acc name ->
          if not (is_record_name name)
          then acc
          else (
            let path = Filename.concat dir name in
            match Unix.lstat path with
            | exception Unix.Unix_error (Unix.ENOENT, _, _) -> acc
            | exception Unix.Unix_error (err, fn, arg) ->
              raise (Sweep_stop (Record_read_failed { name; detail = unix_detail err fn arg }))
            | stat ->
              (match stat.Unix.st_kind with
               | Unix.S_REG -> (name, Int64.of_int stat.Unix.st_size) :: acc
               | Unix.S_LNK ->
                 raise
                   (Sweep_stop
                      (Record_read_failed { name; detail = "symlink in media reading store" }))
               | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> acc)))
       []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
;;

let decode_snapshot raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error detail -> Error ("snapshot is not JSON: " ^ detail)
  | `List values ->
    let rec collect acc = function
      | [] -> Ok acc
      | `String name :: rest when is_record_name name -> collect (Name_set.add name acc) rest
      | _ :: _ -> Error "snapshot carries a non-record entry"
    in
    collect Name_set.empty values
  | _ -> Error "snapshot is not a JSON array"
;;

let snapshot_path ~dir = Filename.concat dir candidate_snapshot_filename

let load_previous_candidates ~dir =
  match Fs_compat.load_owned_regular_file ~ownership_root:dir (snapshot_path ~dir) with
  | Ok None -> Ok None
  | Ok (Some content) ->
    (match decode_snapshot content with
     | Ok names -> Ok (Some names)
     | Error detail -> Error (Snapshot_read_failed { detail }))
  | Error rejection ->
    Error
      (Snapshot_read_failed
         { detail = Fs_compat.owned_regular_file_read_error_to_string rejection })
;;

let save_candidates ~dir names =
  let payload =
    `List (Name_set.elements names |> List.map (fun name -> `String name))
    |> Yojson.Safe.to_string
  in
  match Fs_compat.save_file_atomic (snapshot_path ~dir) payload with
  | Ok () -> Ok ()
  | Error detail -> Error (Snapshot_write_failed { detail })
;;

let delete_records ~dir names sizes =
  let rec loop deleted reclaimed = function
    | [] -> Ok (deleted, reclaimed)
    | name :: rest ->
      (match Unix.unlink (Filename.concat dir name) with
       | () ->
         let size = Option.value ~default:0L (String_map.find_opt name sizes) in
         loop (deleted + 1) (Int64.add reclaimed size) rest
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> loop deleted reclaimed rest
       | exception Unix.Unix_error (err, fn, arg) ->
         Error (Delete_failed { name; detail = unix_detail err fn arg }))
  in
  loop 0 0L (Name_set.elements names)
;;

let store_root_is_directory dir =
  match Unix.lstat dir with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | exception Unix.Unix_error (err, _, _) ->
    Error (Invalid_store_root { dir; detail = Unix.error_message err })
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_DIR -> Ok true
     | Unix.S_LNK -> Error (Invalid_store_root { dir; detail = "symlinked store root" })
     | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
       Error (Invalid_store_root { dir; detail = "store root is not a directory" }))
;;

let keeper_dirs ~masc_dir =
  let root = Filename.concat masc_dir Keeper_media_reading.store_dirname in
  let* present = store_root_is_directory root in
  if not present
  then Ok []
  else (
    match Sys.readdir root with
    | exception Sys_error detail -> Error (Invalid_store_root { dir = root; detail })
    | names ->
      Ok
        (Array.to_list names
         |> List.sort String.compare
         |> List.map (Filename.concat root)
         (* A symlinked keeper directory is kept in the list so [run] reports
            it as a rejected root instead of the listing skipping it. *)
         |> List.filter (fun path ->
           match Unix.lstat path with
           | stat ->
             (match stat.Unix.st_kind with
              | Unix.S_DIR | Unix.S_LNK -> true
              | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> false)
           | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
           (* Unreadable: [run] reports it with the reason. *)
           | exception Unix.Unix_error _ -> true)))
;;

let run ~live ~dir =
  let* present = store_root_is_directory dir in
  if not present
  then Ok empty_report
  else (
    try
      let entries = record_entries ~dir in
      let sizes =
        List.fold_left
          (fun acc (name, size) -> String_map.add name size acc)
          String_map.empty
          entries
      in
      let live_count, candidates =
        List.fold_left
          (fun (live_count, candidates) (name, _) ->
             match record_digest name with
             | Some sha256 when Tool_blob_maintenance.holds_history_media live ~sha256 ->
               live_count + 1, candidates
             | Some _ | None -> live_count, Name_set.add name candidates)
          (0, Name_set.empty)
          entries
      in
      let* previous = load_previous_candidates ~dir in
      let* () = save_candidates ~dir candidates in
      let deletable =
        match previous with
        | None -> Name_set.empty
        | Some previous -> Name_set.inter previous candidates
      in
      let* deleted, reclaimed_bytes = delete_records ~dir deletable sizes in
      let remaining =
        List.filter (fun (name, _) -> not (Name_set.mem name deletable)) entries
      in
      Ok
        { scanned = List.length entries
        ; live = live_count
        ; candidates_recorded = Name_set.cardinal candidates
        ; deleted
        ; reclaimed_bytes
        ; remaining_count = List.length remaining
        ; remaining_bytes = List.fold_left (fun acc (_, size) -> Int64.add acc size) 0L remaining
        }
    with
    | Sweep_stop error -> Error error
    | Sys_error detail -> Error (Invalid_store_root { dir; detail }))
;;
