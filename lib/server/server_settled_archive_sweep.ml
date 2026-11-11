module Store = Lane_addon_store
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Preflight = Keeper_librarian_store_preflight
module Consumer = Server_tool_request_consumer
module Names = Set.Make (String)
open Result.Syntax

type report =
  { live_records : int
  ; named_ids : int
  ; kept_records : int
  ; removed_records : int
  ; removed_record_bytes : int64
  ; removed_bodies : int
  ; removed_body_bytes : int64
  }

type error =
  | Sweep_refused of string
  | Removal_stopped of
      { removed_records : int
      ; removed_bodies : int
      ; detail : string
      }

let error_to_string = function
  | Sweep_refused detail -> "settled archive sweep deleted nothing: " ^ detail
  | Removal_stopped { removed_records; removed_bodies; detail } ->
    Printf.sprintf
      "settled archive sweep stopped after deleting %d records and %d bodies: %s"
      removed_records removed_bodies detail

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
      | Progress.Commit_conflicted _ | Progress.Refused _ | Progress.Refusal_settled _
      | Progress.Observer _ -> [])
    (Progress.events progress)

(* The function each gate inventory groups its records by. [None] for a
   record that names only the request IDs of its progress events. *)
let payload_ids =
  let gate parent original=Result.map (fun id -> [id]) (parent original) in
  function
  | Consumer.Librarian Preflight.Admission_gate ->
    Some (gate Keeper_librarian_admission_gate.parent_execution_id)
  | Consumer.Librarian Preflight.History_gate ->
    Some (gate Keeper_librarian_durable_gate.parent_execution_id)
  | Consumer.Librarian Preflight.Floor_gate ->
    Some (gate Keeper_librarian_floor_step_gate.parent_execution_id)
  | Consumer.Librarian Preflight.Admission_closure -> Some (fun (original:Owner.retained) ->
      let* owner=match original.request with
        | `Assoc fields -> Option.to_result ~none:"Closure has no captured owner" (List.assoc_opt "owner" fields)
        | _ -> Error "Closure payload is not an object" in
      let* owner=Keeper_librarian_admission_capture.owner_of_json owner in
      let+ closure=Keeper_librarian_admission_closure.restore ~owner original in
      Keeper_librarian_admission_closure.named_ids closure)
  | Consumer.Librarian
      ( Preflight.Admission_execution | Preflight.Admission_part | Preflight.Admission_partition
      | Preflight.History_execution | Preflight.Floor_execution )
  | Consumer.One_scope
      ( Consumer.Workspace_curator | Consumer.Completion_review | Consumer.Goal_proof_review
      | Consumer.Candle_appraisal ) -> None

(* Parser errors can carry snippets of private records or bodies, so a
   refusal names only the class of failure. *)
let refuse detail _ = Sweep_refused detail

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
        let* consumer =
          Option.to_result ~none:(Sweep_refused "a live record is in a scope no owner claims")
            (Consumer.of_scope (Owner.Record.scope record))
        in
        let* parent =
          match payload_ids consumer with
          | None -> Ok []
          | Some named_ids ->
            let* original =
              Owner.load_listed ~store record
              |> Result.map_error (refuse "a live gate record could not be loaded")
            in
            let+ ids =
              named_ids original
              |> Result.map_error (refuse "a live gate record names no parent execution")
            in
            ids
        in
        Ok
          (List.fold_left
             (fun names id -> Names.add id names)
             names
             (parent @ progress_ids (Owner.Record.progress record))))
      (Ok Names.empty) records
  in
  Ok (List.length records, names)

(* One archive file the pass decided to delete. *)
type doomed = { path : string; size : int64 }

type plan = { kept : int; records : doomed list; bodies : doomed list }

let sorted_entries path = Sys.readdir path |> Array.to_list |> List.sort String.compare

let is_directory path = (Unix.lstat path).Unix.st_kind = Unix.S_DIR

(* <archive>/<scope digest>/<date>/{records,bodies}/<name>.json. A staging
   file a settle left is skipped; any other shape refuses the pass. *)
let plan_archive ~root ~named_files =
  let archive = Filename.concat root Store.tool_request_archive_directory in
  let directory path =
    if is_directory path then Ok (sorted_entries path)
    else Error (Sweep_refused "an archive entry is not a directory")
  in
  let files path ~init ~f =
    let* names = directory path in
    List.fold_left
      (fun acc name ->
        let* acc = acc in
        if Fs_compat.is_atomic_orphan_name name then Ok acc
        else
          let file = Filename.concat path name in
          let stat = Unix.lstat file in
          if stat.Unix.st_kind = Unix.S_REG && Filename.check_suffix name ".json" then
            Ok (f acc name { path = file; size = Int64.of_int stat.Unix.st_size })
          else Error (Sweep_refused "an archive file is not a JSON record or body"))
      (Ok init) names
  in
  let day path plan =
    let* kinds = directory path in
    List.fold_left
      (fun plan kind ->
        let* plan = plan in
        let path = Filename.concat path kind in
        match kind with
        | "records" ->
          files path ~init:plan ~f:(fun plan name doomed ->
            if Names.mem name named_files then { plan with kept = plan.kept + 1 }
            else { plan with records = doomed :: plan.records })
        | "bodies" ->
          files path ~init:plan ~f:(fun plan _ doomed -> { plan with bodies = doomed :: plan.bodies })
        | _ -> Error (Sweep_refused "an archive day holds an unknown directory"))
      (Ok plan) kinds
  in
  let empty = { kept = 0; records = []; bodies = [] } in
  match Unix.lstat archive with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok empty
  | _ ->
    let* scopes = directory archive in
    List.fold_left
      (fun plan scope ->
        let* plan = plan in
        let path = Filename.concat archive scope in
        let* days = directory path in
        List.fold_left
          (fun plan date ->
            let* plan = plan in
            day (Filename.concat path date) plan)
          (Ok plan) days)
      (Ok empty) scopes

(* Deletes in order and stops at the first failure with how many it deleted. *)
let remove doomed =
  List.fold_left
    (fun acc { path; size } ->
      let* count, bytes = acc in
      match Unix.unlink path with
      | () -> Ok (count + 1, Int64.add bytes size)
      | exception Unix.Unix_error (error, _, _) -> Error (count, Unix.error_message error))
    (Ok (0, 0L)) doomed

let run ~store =
  let* live_records, names = live_names ~store in
  let named_files = Names.map (fun id -> Store.digest id ^ ".json") names in
  let* plan =
    try plan_archive ~root:(Store.root store) ~named_files with
    | Unix.Unix_error (error, operation, _) ->
      Error (Sweep_refused (operation ^ ": " ^ Unix.error_message error))
    | Sys_error _ -> Error (Sweep_refused "an archive directory could not be listed")
  in
  let* removed_bodies, removed_body_bytes =
    remove plan.bodies
    |> Result.map_error (fun (removed_bodies, detail) ->
      Removal_stopped { removed_records = 0; removed_bodies; detail })
  in
  let* removed_records, removed_record_bytes =
    remove plan.records
    |> Result.map_error (fun (removed_records, detail) ->
      Removal_stopped { removed_records; removed_bodies; detail })
  in
  Ok
    { live_records
    ; named_ids = Names.cardinal names
    ; kept_records = plan.kept
    ; removed_records
    ; removed_record_bytes
    ; removed_bodies
    ; removed_body_bytes
    }

let run_at_startup ~base_path =
  let runtime_root = Common.masc_dir_from_base_path ~base_path in
  match Unix.lstat runtime_root with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    Ok
      { live_records = 0
      ; named_ids = 0
      ; kept_records = 0
      ; removed_records = 0
      ; removed_record_bytes = 0L
      ; removed_bodies = 0
      ; removed_body_bytes = 0L
      }
  | exception Unix.Unix_error (error, operation, _) ->
    Error (Sweep_refused (operation ^ ": " ^ Unix.error_message error))
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    run ~store:(Store.create ~root:(Store.directory ~masc_dir:runtime_root))
  | _ -> Error (Sweep_refused "workspace runtime root is not a directory")
