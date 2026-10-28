open Published_artifact

type error =
  | Invalid of string
  | Missing
  | Conflict of { expected : int; actual : int }
  | Unavailable of string
  | Commit_uncertain of { id : string; revision : int; message : string }
type listing =
  { artifacts : Yojson.Safe.t list; diagnostics : (string * string) list }

open Result.Syntax
let error_message = function
  | Invalid message | Unavailable message -> message
  | Commit_uncertain { message; _ } -> message
  | Missing -> "artifact or revision not found"
  | Conflict { expected; actual } ->
    Printf.sprintf "artifact changed: expected revision %d, current revision %d" expected actual

let root ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "published_artifacts"
let path ~base_path id = Filename.concat (root ~base_path) (id ^ ".json")
let share_path ~base_path id = Filename.concat (root ~base_path) (id ^ ".share")

let protect f =
  try f () with
  | Sys_error message -> Error (Unavailable message)
  | Unix.Unix_error (error, operation, _) ->
    Error (Unavailable (operation ^ ": " ^ Unix.error_message error))

let directory_entries ~base_path =
  match Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.geteuid ())
    ~ownership_root:base_path (root ~base_path) with
  | Ok entries -> Ok entries
  | Error error -> Error (Unavailable (Fs_compat.owned_regular_file_read_error_to_string error))

let load ~base_path id =
  match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
    ~ownership_root:base_path (path ~base_path id) with
  | Error _ -> Error (Unavailable "artifact metadata could not be read")
  | Ok None -> Error Missing
  | Ok (Some { content = text; _ }) when not (String.is_valid_utf_8 text) ->
    Error (Unavailable "artifact metadata is not valid UTF-8")
  | Ok (Some { content = text; _ }) ->
    (match Yojson.Safe.from_string text with
     | json ->
       (match Published_artifact.of_json json with
        | Ok artifact when String.equal artifact.id id -> Ok artifact
        | Ok _ -> Error (Unavailable "artifact identity mismatch")
        | Error message -> Error (Unavailable ("invalid artifact metadata: " ^ message)))
     | exception Yojson.Json_error message -> Error (Unavailable message))

let read ~base_path ~id ~revision =
  if not (valid_id id) then Error (Invalid "invalid artifact id")
  else protect (fun () ->
    let* entries = directory_entries ~base_path in
    let* () = match entries with None -> Error Missing | Some _ -> Ok () in
    let* artifact = load ~base_path id in
    let selected = match revision with
      | None -> (match artifact.revisions with [] -> None | r :: _ -> Some r)
      | Some n -> List.find_opt (fun (r : revision) -> r.revision = n) artifact.revisions in
    match selected with
    | None -> Error Missing
    | Some selected ->
      match Tool_blob_store.fetch_bounded (Tool_blob_store.create ~base_path)
        ~sha256:selected.body.sha256 ~max_bytes:Tool_blob_store.max_served_bytes with
      | Ok (Some content) when String.length content = selected.body.bytes ->
        if String.is_valid_utf_8 content then Ok (artifact, selected, content)
        else Error (Unavailable "published body is not valid UTF-8")
      | Ok None -> Error (Unavailable "published body is missing")
      | Ok (Some _) -> Error (Unavailable "published body length mismatch")
      | Error error -> Error (Unavailable (Tool_blob_store.fetch_error_to_string error)))

let list ~base_path = protect (fun () ->
  let* entries = directory_entries ~base_path in
  let files = Option.value ~default:[] entries in
  let artifacts, diagnostics = List.fold_left (fun (entries, diagnostics) filename ->
    if not (Filename.check_suffix filename ".json") then entries, diagnostics
    else
      let id = Filename.remove_extension filename in
      if not (valid_id id) then entries, (filename, "invalid artifact filename") :: diagnostics
      else match load ~base_path id with
        | Ok { revisions = latest :: _; _ } -> (id, latest) :: entries, diagnostics
        | Ok { revisions = []; _ } -> entries, (filename, "empty revision history") :: diagnostics
        | Error error -> entries, (filename, error_message error) :: diagnostics)
    ([], []) files in
  let artifacts = List.sort (fun (id_a, a) (id_b, b) ->
    let order = String.compare b.created_at a.created_at in
    if order = 0 then String.compare id_a id_b else order) artifacts
    |> List.map (fun (id, r) -> summary_to_json ~id r) in
  Ok { artifacts; diagnostics = List.rev diagnostics })

let publish ~base_path ~author (request : request) =
  if String.trim author = "" || not (String.is_valid_utf_8 author)
  then Error (Invalid "author must be a nonblank UTF-8 string")
  else if String.length request.content > Tool_blob_store.max_served_bytes
  then Error (Invalid "artifact exceeds the HTTP artifact body limit")
  else protect (fun () ->
    let dir = root ~base_path in
    let* _ = directory_entries ~base_path in
    let* () = match Keeper_fs_durable_directory.ensure
      ~before_prepare:(fun () -> ()) ~before_directory_fsync:(fun _ -> ())
      ~ownership_root:base_path dir with
      | Ok _ -> Ok ()
      | Error _ -> Error (Unavailable "artifact directory could not be prepared") in
    let* _ = directory_entries ~base_path in
    let id = match request.update with
      | Create -> Random_id.prefixed ~prefix:"artifact-" ~bytes:16
      | Revise { id; _ } -> id in
    let* () = if valid_id id then Ok () else Error (Invalid "invalid artifact id") in
    match File_lock_eio.with_durable_lock_observed
      ~lock_path:(Filename.concat dir (id ^ ".lock")) (fun () ->
        let* previous = match request.update with
          | Create ->
            (match load ~base_path id with
             | Error Missing -> Ok []
             | Ok _ -> Error (Unavailable "generated artifact id already exists")
             | Error ((Invalid _ | Conflict _ | Unavailable _ | Commit_uncertain _) as error) -> Error error)
          | Revise { expected_revision; _ } ->
            let* artifact = load ~base_path id in
            let actual = List.length artifact.revisions in
            if actual <> expected_revision then Error (Conflict { expected = expected_revision; actual })
            else Ok artifact.revisions in
        let body = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path)
          ~bytes:request.content ~mime:(media_type request.format) in
        let revision =
          { revision = List.length previous + 1; title = request.title
          ; summary = request.summary; format = request.format; author
          ; created_at = Types_core.now_iso (); body
          ; task_id = request.task_id; goal_id = request.goal_id } in
        let artifact = { id; revisions = revision :: previous } in
        match Keeper_fs.save_json_durable_atomic ~ownership_root:base_path
          (path ~base_path id) (Published_artifact.to_json artifact) with
        | Ok () -> Ok (artifact, revision)
        | Error error ->
          let message = Keeper_fs.durable_write_error_to_string error in
          Error (if error.renamed then Commit_uncertain { id; revision = revision.revision; message } else Unavailable message)) with
    | File_lock_eio.Lock_not_acquired error ->
      Error (Unavailable (File_lock_eio.durable_lock_error_to_string error))
    | File_lock_eio.Body_completed { value; release_error = None } -> value
    | File_lock_eio.Body_completed { value; release_error = Some error } ->
      Log.Misc.error "artifact publication lock release: %s"
        (File_lock_eio.durable_lock_error_to_string error);
      value)

module Share = Published_artifact_share

type share_error =
  | Share_invalid of string
  | Share_missing
  | Share_operation_reused
  | Share_unavailable of string
  | Share_commit_uncertain of Share.receipt

let share_error_message = function
  | Share_invalid message | Share_unavailable message -> message
  | Share_missing -> "artifact not found"
  | Share_operation_reused -> "share operation id was already used for a different request"
  | Share_commit_uncertain _ -> "share operation may have committed; reconcile the same operation id"

let protect_share f =
  try f () with
  | Sys_error message -> Error (Share_unavailable message)
  | Unix.Unix_error (error, operation, _) ->
    Error (Share_unavailable (operation ^ ": " ^ Unix.error_message error))

let share_artifact_error = function
  | Invalid message -> Share_invalid message
  | Missing -> Share_missing
  | (Conflict _ | Unavailable _ | Commit_uncertain _) as error ->
    Share_unavailable (error_message error)

let load_share ~base_path ~id =
  if not (valid_id id) then Error (Share_invalid "invalid artifact id")
  else
    match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
      ~ownership_root:base_path (share_path ~base_path id) with
    | Error _ -> Error (Share_unavailable "artifact share state could not be read")
    | Ok None ->
      Share.initial ~id ~shared:false
      |> Result.map_error (function
        | Share.Invalid message -> Share_invalid message
        | Share.Operation_reused -> Share_operation_reused)
    | Ok (Some { content = text; _ }) when not (String.is_valid_utf_8 text) ->
      Error (Share_unavailable "artifact share state is not valid UTF-8")
    | Ok (Some { content = text; _ }) ->
      match Yojson.Safe.from_string text with
      | json ->
        (match Share.of_json json with
         | Ok state when String.equal (Share.id state) id -> Ok state
         | Ok _ -> Error (Share_unavailable "artifact share identity mismatch")
         | Error (Share.Invalid message) -> Error (Share_unavailable message)
         | Error Share.Operation_reused -> Error (Share_unavailable "duplicate share operation"))
      | exception Yojson.Json_error message -> Error (Share_unavailable message)

let read_share ~base_path ~id = protect_share (fun () ->
  load_share ~base_path ~id |> Result.map Share.snapshot)

let find_share_receipt ~base_path ~id ~operation_id = protect_share (fun () ->
  match Random_id.parse_uuid_v7 operation_id with
  | Error _ -> Error (Share_invalid "invalid share operation id")
  | Ok canonical when not (String.equal canonical operation_id) ->
    Error (Share_invalid "noncanonical share operation id")
  | Ok _ ->
    load_share ~base_path ~id |> Result.map (fun state -> Share.find state ~operation_id))

let with_share_lock ~base_path ~id f =
  if not (valid_id id) then Error (Share_invalid "invalid artifact id")
  else protect_share (fun () ->
    let dir = root ~base_path in
    let* entries = directory_entries ~base_path |> Result.map_error share_artifact_error in
    let* () = match entries with None -> Error Share_missing | Some _ -> Ok () in
    match File_lock_eio.with_durable_lock_observed
      ~lock_path:(Filename.concat dir (id ^ ".lock")) (fun () ->
        let* _artifact = load ~base_path id |> Result.map_error share_artifact_error in
        let* state = load_share ~base_path ~id in
        f state) with
    | File_lock_eio.Lock_not_acquired error ->
      Error (Share_unavailable (File_lock_eio.durable_lock_error_to_string error))
    | File_lock_eio.Body_completed { value; release_error = None } -> value
    | File_lock_eio.Body_completed { value; release_error = Some error } ->
      Log.Misc.error "artifact share lock release: %s"
        (File_lock_eio.durable_lock_error_to_string error);
      value)

let save_share ~save ~base_path ~id state receipt =
  match save ~ownership_root:base_path
    (share_path ~base_path id) (Share.to_json state) with
  | Ok () -> Ok receipt
  | Error (error : Keeper_fs.durable_write_error) when error.renamed ->
    Error (Share_commit_uncertain receipt)
  | Error error -> Error (Share_unavailable (Keeper_fs.durable_write_error_to_string error))

let change_share_with_save ~save ~base_path ~id request =
  with_share_lock ~base_path ~id (fun state ->
    match Share.apply state request with
    | Error (Share.Invalid message) -> Error (Share_invalid message)
    | Error Share.Operation_reused -> Error Share_operation_reused
    | Ok (Share.Recorded (next, receipt)) -> save_share ~save ~base_path ~id next receipt
    | Ok (Share.Replay receipt) ->
      (* Rewriting even a replay settles a prior rename whose directory sync
         was uncertain before returning its original result. *)
      save_share ~save ~base_path ~id state receipt)

let durable_share_save ~ownership_root path json =
  Keeper_fs.save_json_durable_atomic ~ownership_root path json

let change_share ~base_path ~id request =
  change_share_with_save ~save:durable_share_save ~base_path ~id request

let share_error_to_artifact_error = function
  | Share_invalid message -> Invalid message
  | Share_missing -> Missing
  | (Share_operation_reused | Share_unavailable _ | Share_commit_uncertain _) as error ->
    Unavailable (share_error_message error)

let is_shared ~base_path ~id =
  read_share ~base_path ~id
  |> Result.map (fun (snapshot : Share.snapshot) -> snapshot.shared)
  |> Result.map_error share_error_to_artifact_error

let set_shared ~base_path ~id ~shared =
  with_share_lock ~base_path ~id (fun state ->
    let request : Share.request =
      { operation_id = Random_id.uuid_v7 (); expected_version = (Share.snapshot state).version; requested = shared } in
    match Share.apply state request with
    | Error (Share.Invalid message) -> Error (Share_invalid message)
    | Error Share.Operation_reused | Ok (Share.Replay _) -> Error Share_operation_reused
    | Ok (Share.Recorded (next, ({ outcome = Share.Applied _; _ } as receipt))) ->
      save_share ~save:durable_share_save ~base_path ~id next receipt |> Result.map (fun _ -> shared)
    | Ok (Share.Recorded (_, { outcome = Share.Conflict _; _ })) ->
      Error (Share_unavailable "share version changed while holding its lock"))
  |> Result.map_error share_error_to_artifact_error

module For_testing = struct
  let change_share_before_stage ~before_stage ~base_path ~id request =
    let save ~ownership_root path json =
      Keeper_fs.For_testing.save_json_durable_atomic ~before_stage ~ownership_root path json in
    change_share_with_save ~save ~base_path ~id request
end
