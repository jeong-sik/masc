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

(* [lockf] locks belong to a process, so its in-process mutex must use the
   same key for every spelling of the same directory. The directory is
   verified before this is called; only the lock key is canonicalized. *)
let lock_path ~base_path id =
  Filename.concat (Unix.realpath (root ~base_path)) (id ^ ".lock")

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
      ~lock_path:(lock_path ~base_path id) (fun () ->
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

let share_guard_path ~base_path id = Filename.concat (root ~base_path) (id ^ ".share-v3")
let share_receipt_dir ~base_path id = Filename.concat (root ~base_path) (id ^ ".share-receipts")
let share_receipt_path ~base_path id operation_id =
  Filename.concat (share_receipt_dir ~base_path id) operation_id

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

let load_share_json ~base_path path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
      ~single_link:true ~ownership_root:base_path path with
  | Error _ -> Error (Share_unavailable "share metadata could not be read")
  | Ok None -> Ok None
  | Ok (Some { content; _ }) when not (String.is_valid_utf_8 content) ->
    Error (Share_unavailable "share metadata is not valid UTF-8")
  | Ok (Some { content; _ }) ->
    match Yojson.Safe.from_string content with
    | json -> Ok (Some json)
    | exception Yojson.Json_error message -> Error (Share_unavailable message)

type share_guard =
  | Guard_absent
  | Guard_active
  | Guard_pending of { previous : Yojson.Safe.t option; next : Share.t }

let active_guard_json id =
  `Assoc ["schema", `String "masc.published_artifact_share_guard.v2";
          "id", `String id; "phase", `String "active"]

let pending_guard_json ~id ~previous ~next =
  `Assoc ["schema", `String "masc.published_artifact_share_guard.v2";
          "id", `String id; "phase", `String "pending";
          "previous", Option.value ~default:`Null previous; "next", Share.to_json next]

let decode_share_state ~id = function
  | None -> Share.initial ~id ~shared:false |> Result.map_error (function
      | Share.Invalid message -> Share_invalid message
      | Share.Operation_reused -> Share_operation_reused)
  | Some json ->
    (match Share.of_json json with
     | Ok state when String.equal (Share.id state) id -> Ok state
     | Ok _ -> Error (Share_unavailable "artifact share identity mismatch")
     | Error (Share.Invalid message) -> Error (Share_unavailable message)
     | Error Share.Operation_reused -> Error (Share_unavailable "duplicate share operation"))

let is_legacy_share = function
  | None -> true
  | Some (`Assoc fields) -> List.sort String.compare (List.map fst fields) = ["id"; "shared"]
  | Some _ -> false

let read_share_guard ~base_path ~id =
  let* guard = load_share_json ~base_path (share_guard_path ~base_path id) in
  match guard with
  | None -> Ok Guard_absent
  | Some (`Assoc fields) when
      List.sort compare fields =
      List.sort compare ["schema", `String "masc.published_artifact_share_guard.v2";
                         "id", `String id; "phase", `String "active"] -> Ok Guard_active
  | Some (`Assoc fields) when
      List.sort String.compare (List.map fst fields) = ["id"; "next"; "phase"; "previous"; "schema"] ->
    (match List.assoc "schema" fields, List.assoc "id" fields, List.assoc "phase" fields with
     | `String "masc.published_artifact_share_guard.v2", `String stored_id, `String "pending"
       when String.equal stored_id id ->
       let previous = match List.assoc "previous" fields with `Null -> None | json -> Some json in
       let* initial = if is_legacy_share previous then decode_share_state ~id previous
         else Error (Share_unavailable "invalid share migration baseline") in
       let* next = decode_share_state ~id (Some (List.assoc "next" fields)) in
       (match Share.latest next with
        | Some receipt ->
          (match Share.apply initial receipt.request with
           | Ok (Share.Recorded (expected, _)) when Share.to_json expected = Share.to_json next ->
             Ok (Guard_pending { previous; next })
           | Ok (Share.Recorded _ | Share.Replay _) | Error _ ->
             Error (Share_unavailable "invalid share migration transition"))
        | None -> Error (Share_unavailable "share migration receipt is missing"))
     | _ -> Error (Share_unavailable "invalid artifact share guard"))
  | Some _ -> Error (Share_unavailable "invalid artifact share guard")

let load_share ~base_path ~id =
  if not (valid_id id) then Error (Share_invalid "invalid artifact id")
  else
    let* guard = read_share_guard ~base_path ~id in
    let* json = load_share_json ~base_path (share_path ~base_path id) in
    let legacy = is_legacy_share json in
    let* archive_present =
      if guard <> Guard_absent || not legacy then Ok false
      else match Unix.lstat (share_receipt_dir ~base_path id) with
        | _ -> Ok true
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false in
    match guard with
    | Guard_pending _ -> Error (Share_unavailable "artifact share migration requires recovery")
    | Guard_active when legacy -> Error (Share_unavailable "artifact share state requires recovery")
    | Guard_absent when not legacy -> Error (Share_unavailable "artifact share state requires recovery")
    | Guard_absent when archive_present -> Error (Share_unavailable "artifact share history exists without its guard")
    | Guard_active | Guard_absent -> decode_share_state ~id json

let read_share ~base_path ~id = protect_share (fun () ->
  load_share ~base_path ~id |> Result.map Share.snapshot)

let load_archived_receipt ~base_path ~id ~state ~operation_id =
  let* json = load_share_json ~base_path (share_receipt_path ~base_path id operation_id) in
  match json with
  | None -> Ok None
  | Some (`Assoc fields) when List.sort String.compare (List.map fst fields) = ["id"; "receipt"; "schema"] ->
    (match List.assoc "schema" fields, List.assoc "id" fields with
     | `String "masc.published_artifact_share_receipt.v1", `String stored_id when String.equal stored_id id ->
       (match Share.receipt_of_json (List.assoc "receipt" fields) with
        | Ok receipt when String.equal receipt.request.operation_id operation_id &&
            (Share.receipt_snapshot receipt).version <= (Share.snapshot state).version -> Ok (Some receipt)
        | Ok _ | Error _ -> Error (Share_unavailable "invalid archived share receipt"))
     | _ -> Error (Share_unavailable "invalid archived share receipt identity"))
  | Some _ -> Error (Share_unavailable "invalid archived share receipt")

let lookup_receipt ~base_path ~id ~state ~operation_id =
  match Share.latest state with
  | Some receipt when String.equal receipt.request.operation_id operation_id -> Ok (Some receipt)
  | Some _ | None -> load_archived_receipt ~base_path ~id ~state ~operation_id

let find_share_receipt ~base_path ~id ~operation_id = protect_share (fun () ->
  if not (Share.valid_operation_id operation_id) then Error (Share_invalid "invalid share operation id")
  else let* state = load_share ~base_path ~id in
    lookup_receipt ~base_path ~id ~state ~operation_id)

let durable_share_save ~ownership_root path json =
  Keeper_fs.save_json_durable_atomic ~ownership_root path json

let recover_pending_share ~base_path ~id =
  let* guard = read_share_guard ~base_path ~id in
  match guard with
  | Guard_absent | Guard_active -> Ok ()
  | Guard_pending { previous; next } ->
    let* current = load_share_json ~base_path (share_path ~base_path id) in
    if current <> previous && current <> Some (Share.to_json next) then
      Error (Share_unavailable "share migration baseline changed")
    else
      let save path json =
        match durable_share_save ~ownership_root:base_path path json with
        | Ok () -> Ok ()
        | Error error -> Error (Share_unavailable (Keeper_fs.durable_write_error_to_string error)) in
      let* () = save (share_path ~base_path id) (Share.to_json next) in
      save (share_guard_path ~base_path id) (active_guard_json id)

let with_share_lock ~base_path ~id f =
  if not (valid_id id) then Error (Share_invalid "invalid artifact id")
  else protect_share (fun () ->
    let* entries = directory_entries ~base_path |> Result.map_error share_artifact_error in
    let* () = match entries with None -> Error Share_missing | Some _ -> Ok () in
    match File_lock_eio.with_durable_lock_observed
      ~lock_path:(lock_path ~base_path id) (fun () ->
        let* _artifact = load ~base_path id |> Result.map_error share_artifact_error in
        let* () = recover_pending_share ~base_path ~id in
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

let archive_receipt ~base_path ~id ~state receipt =
  let operation_id = receipt.Share.request.operation_id in
  let* previous = load_archived_receipt ~base_path ~id ~state ~operation_id in
  match previous with
  | Some existing when existing <> receipt -> Error (Share_unavailable "share receipt identity mismatch")
  | Some _ | None ->
    let json = `Assoc ["schema", `String "masc.published_artifact_share_receipt.v1";
      "id", `String id; "receipt", Share.receipt_to_json receipt] in
    match durable_share_save ~ownership_root:base_path (share_receipt_path ~base_path id operation_id) json with
    | Ok () -> Ok ()
    | Error error -> Error (Share_unavailable (Keeper_fs.durable_write_error_to_string error))

let change_share_with_save ~save ~base_path ~id request =
  with_share_lock ~base_path ~id (fun state ->
    if not (Share.valid_operation_id request.Share.operation_id) then Error (Share_invalid "invalid share operation id")
    else let* existing = lookup_receipt ~base_path ~id ~state ~operation_id:request.operation_id in
    match existing with
    | Some receipt when receipt.request <> request -> Error Share_operation_reused
    | Some receipt -> save_share ~save ~base_path ~id state receipt
    | None ->
      match Share.apply state request with
      | Error (Share.Invalid message) -> Error (Share_invalid message)
      | Error Share.Operation_reused | Ok (Share.Replay _) -> Error Share_operation_reused
      | Ok (Share.Recorded (next, receipt)) ->
        let* guard = read_share_guard ~base_path ~id in
        match guard with
        | Guard_pending _ -> Error (Share_unavailable "artifact share migration requires recovery")
        | Guard_absent ->
          let* previous = load_share_json ~base_path (share_path ~base_path id) in
          let pending = pending_guard_json ~id ~previous ~next in
          (match durable_share_save ~ownership_root:base_path (share_guard_path ~base_path id) pending with
           | Error error when error.renamed -> Error (Share_commit_uncertain receipt)
           | Error error -> Error (Share_unavailable (Keeper_fs.durable_write_error_to_string error))
           | Ok () ->
             (* Once the pending guard is durable, recovery may still apply
                this request even if writing the snapshot fails before rename. *)
             (match save_share ~save ~base_path ~id next receipt with
              | Error _ -> Error (Share_commit_uncertain receipt)
              | Ok _ ->
                match durable_share_save ~ownership_root:base_path
                    (share_guard_path ~base_path id) (active_guard_json id) with
                | Ok () -> Ok receipt
                | Error _ -> Error (Share_commit_uncertain receipt)))
        | Guard_active ->
          let* () = match Share.latest state with
            | None -> Ok ()
            | Some previous ->
              (* A visible rename may not yet be durable. Settle it before its
                 receipt can be archived in a different directory. *)
              let* () = match save_share ~save:durable_share_save ~base_path ~id state previous with
                | Ok _ -> Ok ()
                | Error (Share_commit_uncertain _) ->
                  Error (Share_unavailable "previous share state could not be settled")
                | Error ((Share_invalid _ | Share_missing | Share_operation_reused | Share_unavailable _) as error) -> Error error in
              archive_receipt ~base_path ~id ~state previous in
          save_share ~save ~base_path ~id next receipt)

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
  let* snapshot = read_share ~base_path ~id |> Result.map_error share_error_to_artifact_error in
  let request : Share.request =
    { operation_id = Random_id.uuid_v7 (); expected_version = snapshot.version; requested = shared } in
  let* receipt = change_share ~base_path ~id request |> Result.map_error share_error_to_artifact_error in
  match receipt.Share.outcome with
    | Share.Applied state -> Ok state.shared
    | Share.Conflict _ -> Error (Unavailable "share version changed; reread before retrying")

module For_testing = struct
  let change_share_before_stage ~before_stage ~base_path ~id request =
    let save ~ownership_root path json =
      Keeper_fs.For_testing.save_json_durable_atomic ~before_stage ~ownership_root path json in
    change_share_with_save ~save ~base_path ~id request
end
