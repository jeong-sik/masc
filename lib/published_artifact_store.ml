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

let with_latest_locked ~base_path ~id ~expected_revision ~f =
  if not (valid_id id) then Error (Invalid "invalid artifact id")
  else if expected_revision <= 0 then Error (Invalid "expected revision must be positive")
  else
    let* () = protect (fun () ->
      let* entries = directory_entries ~base_path in
      match entries with None -> Error Missing | Some _ -> Ok ()) in
    match File_lock_eio.with_durable_lock_observed
      ~lock_path:(Filename.concat (root ~base_path) (id ^ ".lock")) (fun () ->
        (* The admitted lock scope protects cancellation until the callback
           and release settle. Read, hash and callback work can be large, so
           run the blocking portion outside the Eio scheduler. *)
        Eio_guard.run_in_systhread ~label:"artifact-publication-checkpoint" (fun () ->
          let* _, latest, content = read ~base_path ~id ~revision:None in
          if latest.revision <> expected_revision then
            Error (Conflict { expected = expected_revision; actual = latest.revision })
          else Ok (f latest content))) with
    | File_lock_eio.Lock_not_acquired error ->
      Error (Unavailable (File_lock_eio.durable_lock_error_to_string error))
    | File_lock_eio.Body_completed { value; release_error = None } -> value
    | File_lock_eio.Body_completed { value; release_error = Some error } ->
      (* The callback may have durably committed another store. A failed lock
         release must not erase that result or authorize another attempt. *)
      Log.Misc.error "artifact publication lock release: %s"
        (File_lock_eio.durable_lock_error_to_string error);
      value

let catalog ~base_path = protect (fun () ->
  let* entries = directory_entries ~base_path in
  let files = Option.value ~default:[] entries in
  let artifacts, diagnostics = List.fold_left (fun (entries, diagnostics) filename ->
    if not (Filename.check_suffix filename ".json") then entries, diagnostics
    else
      let id = Filename.remove_extension filename in
      if not (valid_id id) then entries, (filename, "invalid artifact filename") :: diagnostics
      else match load ~base_path id with
        | Ok { revisions = latest :: _ as revisions; _ } ->
          let authors = List.map (fun (revision : revision) -> revision.author) revisions
            |> List.sort_uniq String.compare in
          (id, latest, authors) :: entries, diagnostics
        | Ok { revisions = []; _ } -> entries, (filename, "empty revision history") :: diagnostics
        | Error error -> entries, (filename, error_message error) :: diagnostics)
    ([], []) files in
  let artifacts = List.sort (fun (id_a, a, _) (id_b, b, _) ->
    let order = String.compare b.created_at a.created_at in
    if order = 0 then String.compare id_a id_b else order) artifacts in
  Ok (artifacts, List.rev diagnostics))

let list ~base_path =
  let* artifacts, diagnostics = catalog ~base_path in
  Ok { artifacts = List.map (fun (id, revision, _) -> summary_to_json ~id revision) artifacts;
       diagnostics }

let list_with_authors ~base_path =
  let* artifacts, diagnostics = catalog ~base_path in
  let* artifacts = List.fold_left (fun collected (id, revision, authors) ->
    let* collected = collected in
    match summary_to_json ~id revision with
    | `Assoc fields -> Ok (`Assoc (("authors", `List (List.map (fun author -> `String author) authors)) :: fields) :: collected)
    | _ -> Error (Unavailable "invalid artifact summary")) (Ok []) artifacts in
  Ok { artifacts = List.rev artifacts; diagnostics }

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
        let previous_task_id, previous_goal_id = match previous with
          | [] -> None, None
          | (prior : revision) :: _ -> prior.task_id, prior.goal_id in
        let resolve_link change previous = match change with
          | Unspecified -> previous
          | Clear -> None
          | Set value -> Some value in
        let task_id = resolve_link request.task_id previous_task_id
        and goal_id = resolve_link request.goal_id previous_goal_id in
        let revision =
          { revision = List.length previous + 1; title = request.title
          ; summary = request.summary; format = request.format; author
          ; created_at = Types_core.now_iso (); body
          ; task_id; goal_id } in
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

let is_shared ~base_path ~id =
  if not (valid_id id) then Error (Invalid "invalid artifact id")
  else protect (fun () ->
    match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
      ~ownership_root:base_path (share_path ~base_path id) with
    | Error _ -> Error (Unavailable "artifact share state could not be read")
    | Ok None -> Ok false
    | Ok (Some { content = text; _ }) when not (String.is_valid_utf_8 text) ->
      Error (Unavailable "artifact share state is not valid UTF-8")
    | Ok (Some { content = text; _ }) ->
      match Yojson.Safe.from_string text with
      | `Assoc ["id", `String stored_id; "shared", `Bool shared]
      | `Assoc ["shared", `Bool shared; "id", `String stored_id]
        when String.equal stored_id id -> Ok shared
      | _ -> Error (Unavailable "invalid artifact share metadata")
      | exception Yojson.Json_error message -> Error (Unavailable message))

let set_shared ~base_path ~id ~shared =
  if not (valid_id id) then Error (Invalid "invalid artifact id")
  else protect (fun () ->
    let dir = root ~base_path in
    let* entries = directory_entries ~base_path in
    let* () = match entries with None -> Error Missing | Some _ -> Ok () in
    match File_lock_eio.with_durable_lock_observed
      ~lock_path:(Filename.concat dir (id ^ ".lock")) (fun () ->
        let* _artifact = load ~base_path id in
        let json = `Assoc ["id", `String id; "shared", `Bool shared] in
        match Keeper_fs.save_json_durable_atomic ~ownership_root:base_path
          (share_path ~base_path id) json with
        | Ok () -> Ok shared
        | Error error ->
          Error (Unavailable (Keeper_fs.durable_write_error_to_string error))) with
    | File_lock_eio.Lock_not_acquired error ->
      Error (Unavailable (File_lock_eio.durable_lock_error_to_string error))
    | File_lock_eio.Body_completed { value; release_error = None } -> value
    | File_lock_eio.Body_completed { value; release_error = Some error } ->
      Log.Misc.error "artifact share lock release: %s"
        (File_lock_eio.durable_lock_error_to_string error);
      value)
