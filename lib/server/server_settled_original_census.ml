module Store = Lane_addon_store
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Preflight = Keeper_librarian_store_preflight
module Names = Set.Make (String)
open Result.Syntax

type report =
  { live_records : int
  ; named_ids : int
  ; archived_records : int
  ; archived_record_bytes : int64
  ; unnamed_records : int
  ; unnamed_record_bytes : int64
  ; archived_bodies : int
  ; archived_body_bytes : int64
  }

type error = Census_unavailable of string

let error_to_string (Census_unavailable detail) =
  "settled original census unavailable: " ^ detail

(* Every owner that keeps records under tool-request-owners. The review
   owners and the Curator each keep one fixed scope; a Librarian scope is
   named by the producer that owns its kind. *)
type kind =
  | Librarian of Preflight.purpose
  | Workspace_curator
  | Completion_review
  | Goal_proof_review

let kind_of_scope scope =
  if String.equal scope Workspace_memory_execution_capture.scope then Some Workspace_curator
  else if String.equal scope Verifier_review_owner.scope then Some Completion_review
  else if String.equal scope Goal_verifier_worker.scope then Some Goal_proof_review
  else Option.map (fun purpose -> Librarian purpose) (Preflight.purpose scope)

let progress_ids progress =
  List.concat_map
    (function
      | Progress.Preparation_intended { request_id; _ }
      | Progress.Replacement_intended { request_id; _ } -> [ request_id ]
      | Progress.Successor_intended { request_id; _ } -> [ request_id ]
      | Progress.Preparation_observed request_id
      | Progress.Replacement_observed request_id
      | Progress.Successor_observed request_id -> [ request_id ]
      | Progress.Dispatch_intended | Progress.Admission_declined _
      | Progress.Execution_observed _ | Progress.Judgment_retained _
      | Progress.Commit_intended _ | Progress.Commit_uncertain _
      | Progress.Commit_retry_observed _ | Progress.Commit_observed _
      | Progress.Commit_conflicted _ | Progress.Refused _ | Progress.Observer _ -> [])
    (Progress.events progress)

(* The function each gate inventory groups its records by. *)
let gate_parent = function
  | Librarian Preflight.Admission_gate -> Some Keeper_librarian_admission_gate.parent_execution_id
  | Librarian Preflight.History_gate -> Some Keeper_librarian_durable_gate.parent_execution_id
  | Librarian Preflight.Floor_gate -> Some Keeper_librarian_floor_step_gate.parent_execution_id
  | Librarian
      ( Preflight.Admission_execution | Preflight.Admission_part | Preflight.Admission_partition
      | Preflight.History_execution | Preflight.Floor_execution )
  | Workspace_curator | Completion_review | Goal_proof_review -> None

(* Parser errors can carry snippets of private records or bodies, so a
   refusal names only the class of failure. *)
let refuse detail _ = Census_unavailable detail

let live_names ~store =
  let* records =
    Store.fold_startup_tool_request_owners store ~init:[]
      ~f:(fun records ~directory_name ~file_name json ->
        let* record = Owner.decode_published ~directory_name ~file_name json in
        Ok (record :: records))
    |> Result.map_error (refuse "a live record could not be read")
  in
  let* names =
    List.fold_left
      (fun names record ->
        let* names = names in
        let* kind =
          Option.to_result ~none:(Census_unavailable "a live record is in a scope no owner claims")
            (kind_of_scope (Owner.Record.scope record))
        in
        let* parent =
          match gate_parent kind with
          | None -> Ok []
          | Some parent_execution_id ->
            let* original =
              Owner.load_listed ~store record
              |> Result.map_error (refuse "a live gate record could not be loaded")
            in
            let+ id =
              parent_execution_id original
              |> Result.map_error (refuse "a live gate record names no parent execution")
            in
            [ id ]
        in
        Ok
          (List.fold_left
             (fun names id -> Names.add id names)
             names
             (parent @ progress_ids (Owner.Record.progress record))))
      (Ok Names.empty) records
  in
  Ok (List.length records, names)

type archived = { files : int; bytes : int64; unnamed : int; unnamed_bytes : int64 }

let empty = { files = 0; bytes = 0L; unnamed = 0; unnamed_bytes = 0L }

let add ~named archived size =
  let bytes = Int64.add archived.bytes size in
  if named then { archived with files = archived.files + 1; bytes }
  else
    { files = archived.files + 1
    ; bytes
    ; unnamed = archived.unnamed + 1
    ; unnamed_bytes = Int64.add archived.unnamed_bytes size
    }

let sorted_entries path = Sys.readdir path |> Array.to_list |> List.sort String.compare

let is_directory path = (Unix.lstat path).Unix.st_kind = Unix.S_DIR

(* <archive>/<scope digest>/<date>/{records,bodies}/<name>.json. A staging
   file a settle left is skipped; any other shape refuses the count. *)
let walk_archive ~root ~named_files =
  let archive = Filename.concat root Store.tool_request_archive_directory in
  let directory path =
    if is_directory path then Ok (sorted_entries path)
    else Error (Census_unavailable "an archive entry is not a directory")
  in
  let files path ~init ~f =
    let* names = directory path in
    List.fold_left
      (fun acc name ->
        let* acc = acc in
        if Fs_compat.is_atomic_orphan_name name then Ok acc
        else
          let stat = Unix.lstat (Filename.concat path name) in
          if stat.Unix.st_kind = Unix.S_REG && Filename.check_suffix name ".json" then
            Ok (f acc name (Int64.of_int stat.Unix.st_size))
          else Error (Census_unavailable "an archive file is not a JSON record or body"))
      (Ok init) names
  in
  let day path (records, bodies) =
    let* kinds = directory path in
    List.fold_left
      (fun acc kind ->
        let* records, bodies = acc in
        let path = Filename.concat path kind in
        match kind with
        | "records" ->
          let+ records =
            files path ~init:records ~f:(fun records name size ->
              add ~named:(Names.mem name named_files) records size)
          in
          (records, bodies)
        | "bodies" ->
          let+ bodies = files path ~init:bodies ~f:(fun bodies _ size -> add ~named:true bodies size) in
          (records, bodies)
        | _ -> Error (Census_unavailable "an archive day holds an unknown directory"))
      (Ok (records, bodies)) kinds
  in
  match Unix.lstat archive with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok (empty, empty)
  | _ ->
    let* scopes = directory archive in
    List.fold_left
      (fun acc scope ->
        let* acc = acc in
        let path = Filename.concat archive scope in
        let* days = directory path in
        List.fold_left
          (fun acc date ->
            let* acc = acc in
            day (Filename.concat path date) acc)
          (Ok acc) days)
      (Ok (empty, empty)) scopes

let run ~store =
  let* live_records, names = live_names ~store in
  let named_files = Names.map (fun id -> Store.digest id ^ ".json") names in
  let* records, bodies =
    try walk_archive ~root:(Store.root store) ~named_files with
    | Unix.Unix_error (error, operation, _) ->
      Error (Census_unavailable (operation ^ ": " ^ Unix.error_message error))
    | Sys_error _ -> Error (Census_unavailable "an archive directory could not be listed")
  in
  Ok
    { live_records
    ; named_ids = Names.cardinal names
    ; archived_records = records.files
    ; archived_record_bytes = records.bytes
    ; unnamed_records = records.unnamed
    ; unnamed_record_bytes = records.unnamed_bytes
    ; archived_bodies = bodies.files
    ; archived_body_bytes = bodies.bytes
    }

let run_at_startup ~base_path =
  let runtime_root = Common.masc_dir_from_base_path ~base_path in
  match Unix.lstat runtime_root with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    Ok
      { live_records = 0
      ; named_ids = 0
      ; archived_records = 0
      ; archived_record_bytes = 0L
      ; unnamed_records = 0
      ; unnamed_record_bytes = 0L
      ; archived_bodies = 0
      ; archived_body_bytes = 0L
      }
  | exception Unix.Unix_error (error, operation, _) ->
    Error (Census_unavailable (operation ^ ": " ^ Unix.error_message error))
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    run ~store:(Store.create ~root:(Filename.concat runtime_root "lane-addons"))
  | _ -> Error (Census_unavailable "workspace runtime root is not a directory")
