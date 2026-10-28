module Data = Artifact_app_data
module Artifacts = Published_artifact_store
type error =
  | Invalid of string
  | Artifact_error of Artifacts.error
  | Conflict of Data.t
  | Request_collision
  | Unavailable of string
  | Commit_uncertain of Data.t
open Result.Syntax
let error_message = function
  | Invalid message | Unavailable message -> message
  | Artifact_error error -> Artifacts.error_message error
  | Conflict _ -> "application inputs changed in another window; reread before saving"
  | Request_collision -> "application input request id was already used for different inputs"
  | Commit_uncertain _ -> "application inputs may have been saved; reread before retrying"
let root ~base_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "artifact_app_data"
let filename ~actor (target : Data.target) =
  let owner = Agent_core_sha256.(to_hex (digest_string actor)) in
  target.artifact_id ^ "-r" ^ string_of_int target.revision ^ "-" ^ owner ^ ".json"
let protect f = try f () with
  | Sys_error message -> Error (Unavailable message)
  | Unix.Unix_error (error, operation, _) -> Error (Unavailable (operation ^ ": " ^ Unix.error_message error))
let directory ~base_path =
  Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.geteuid ()) ~ownership_root:base_path (root ~base_path)
  |> Result.map_error (fun error -> Unavailable (Fs_compat.owned_regular_file_read_error_to_string error))
let prepare ~base_path =
  let* _ = directory ~base_path in
  let* _ = Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
    ~before_directory_fsync:(fun _ -> ()) ~ownership_root:base_path (root ~base_path)
    |> Result.map_error (fun _ -> Unavailable "application input directory could not be prepared") in
  let* _ = directory ~base_path in Ok ()
let authorize ~base_path ~actor target =
  let* empty = Data.empty ~target ~actor |> Result.map_error (fun message -> Invalid message) in
  let* _, revision, _ = Artifacts.read ~base_path ~id:target.Data.artifact_id ~revision:(Some target.revision)
    |> Result.map_error (fun error -> Artifact_error error) in
  match revision.format with
  | Published_artifact.Html -> Ok empty
  | Markdown -> Error (Invalid "application inputs require a published HTML revision")
let load ~base_path empty =
  let file = Filename.concat (root ~base_path) (filename ~actor:empty.Data.actor empty.target) in
  let check file =
    let* observed = Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
      ~ownership_root:base_path file
      |> Result.map_error (fun _ -> Unavailable "application input path is not an owned regular file") in
    match observed with
    | Some observed when observed.snapshot.permissions <> 0o600 ->
      Error (Unavailable "application input files must have private 0600 permissions")
    | None | Some _ -> Ok () in
  let* _ = check file in let* _ = check (Fs_compat.private_jsonl_lock_path file) in
  let* snapshot = Fs_compat.read_private_jsonl_durable_locked_result file ~after:None
    |> Result.map_error (fun error -> Unavailable (Fs_compat.private_jsonl_transaction_error_to_string error)) in
  let* state = if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor then Ok empty
    else if not (String.is_valid_utf_8 snapshot.bytes) then Error (Unavailable "application input state is not UTF-8")
    else match Yojson.Safe.from_string snapshot.bytes with
      | json ->
        let* state = Data.of_json json |> Result.map_error (fun message -> Unavailable message) in
        if state.target = empty.target && state.actor = empty.actor then Ok state
        else Error (Unavailable "application input filename identity mismatch")
      | exception Yojson.Json_error _ -> Error (Unavailable "invalid application input JSON") in
  Ok (file, snapshot, state)
let read ~base_path ~actor target = protect (fun () ->
  let* empty = authorize ~base_path ~actor target in
  let* exists = directory ~base_path in
  match exists with None -> Ok empty | Some _ -> let* _, _, state = load ~base_path empty in Ok state)
let set_with_rewrite ~rewrite ~base_path ~actor (request : Data.request) = protect (fun () ->
  let* empty = authorize ~base_path ~actor request.target in
  let* () = prepare ~base_path in
  let rec attempt () =
    let* file, snapshot, previous = load ~base_path empty in
    let* state = Data.apply previous ~at:(Types_core.now_iso ()) request |> Result.map_error (function
      | Data.Invalid message -> Invalid message | Conflict -> Conflict previous | Request_collision -> Request_collision) in
    if state.version = previous.version then Ok previous
    else
      let rec failed = function
        | Fs_compat.Cursor_mismatch _ -> attempt ()
        | Rewrite_published_durability_unknown _ -> Error (Commit_uncertain state)
        | Transaction_settlement_failed { primary = Transaction_succeeded (Cursor_succeeded _); _ } -> Error (Commit_uncertain state)
        | Transaction_settlement_failed { primary = Transaction_failed error; _ } -> failed error
        | (Transaction_settlement_failed { primary = Transaction_succeeded (Snapshot_succeeded _ | Cursor_precondition_succeeded _); _ }
          | Stable_lock_contended _ | Unexpected_stable_lock_permissions _ | Invalid_stable_lock_state _
          | Unexpected_transaction_file_kind _ | Ambiguous_transaction_file_identity _ | Transaction_path_binding_changed _
          | Transaction_content_changed _ | Incomplete_transaction_tail _ | Invalid_transaction_suffix
          | Private_jsonl_operation_failed _ | Rewrite_stage_failed _ | Transaction_append_failed _) as error ->
          Error (Unavailable (Fs_compat.private_jsonl_transaction_error_to_string error)) in
      match rewrite file ~expected:snapshot.cursor (Yojson.Safe.to_string (Data.to_json state) ^ "\n") with
      | Ok _ -> Ok state | Error error -> failed error in
  attempt ())
let set ~base_path ~actor request =
  set_with_rewrite ~rewrite:Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result ~base_path ~actor request
module For_testing = struct
  let set_with_rewrite_io ~io ~base_path ~actor request =
    set_with_rewrite ~rewrite:(Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_with_io_for_testing ~io)
      ~base_path ~actor request
end
