open Artifact_project_source

type error =
  | Invalid of string
  | Missing
  | Unavailable of string
  | Commit_uncertain of { id : string; message : string }
let error_message = function
  | Invalid message | Unavailable message | Commit_uncertain { message; _ } -> message
  | Missing -> "project source not found"
open Result.Syntax
let root ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "artifact_project_sources"
let path ~base_path id = Filename.concat (root ~base_path) (id ^ ".json")
let protect f =
  try f () with
  | Sys_error message -> Error (Unavailable message)
  | Unix.Unix_error (error, operation, _) ->
    Error (Unavailable (operation ^ ": " ^ Unix.error_message error))
let directory ~base_path =
  match Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.geteuid ())
    ~ownership_root:base_path (root ~base_path) with
  | Ok entries -> Ok entries
  | Error error -> Error (Unavailable (Fs_compat.owned_regular_file_read_error_to_string error))
let load ~base_path id =
  match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
    ~ownership_root:base_path (path ~base_path id) with
  | Error error -> Error (Unavailable (Fs_compat.owned_regular_file_read_error_to_string error))
  | Ok None -> Error Missing
  | Ok (Some { snapshot; _ }) when snapshot.permissions <> 0o600 ->
    Error (Unavailable "project source metadata must have private read/write permissions")
  | Ok (Some { content; _ }) when not (String.is_valid_utf_8 content) ->
    Error (Unavailable "project source metadata is not UTF-8")
  | Ok (Some { content; _ }) ->
    (match Yojson.Safe.from_string content with
     | json ->
       (match Artifact_project_source.of_json json with
        | Ok source when String.equal source.id id -> Ok source
        | Ok _ -> Error (Unavailable "project source identity mismatch")
        | Error message -> Error (Unavailable ("invalid project source metadata: " ^ message)))
     | exception Yojson.Json_error message -> Error (Unavailable message))
let read_metadata ~base_path ~id =
  if not (valid_id id) then Error (Invalid "invalid project source id")
  else protect (fun () ->
    let* entries = directory ~base_path in
    let* () = match entries with None -> Error Missing | Some _ -> Ok () in
    load ~base_path id)
let read ~base_path ~id = protect (fun () ->
    let* source = read_metadata ~base_path ~id in
    let blobs = Tool_blob_store.create ~base_path in
    let* files = List.fold_left (fun acc (file : stored_file) ->
      let* acc = acc in
      match Tool_blob_store.fetch blobs ~sha256:file.body.sha256 with
      | Ok (Some content) when String.length content = file.body.bytes ->
        Ok (`Assoc ["path", `String file.path;
                    "content_base64", `String (Base64.encode_string content)] :: acc)
      | Ok None -> Error (Unavailable ("project file is missing: " ^ file.path))
      | Ok (Some _) -> Error (Unavailable ("project file length mismatch: " ^ file.path))
      | Error error -> Error (Unavailable (Tool_blob_store.fetch_error_to_string error)))
      (Ok []) source.files in
    let request_json = `Assoc ["schema", `String "masc.artifact_project.v1";
      "build", Artifact_project_source.build_to_json source.build;
      "install_scripts", `Bool source.install_scripts; "files", `List (List.rev files)] in
    let* request = Artifact_project_source.request_of_json request_json
      |> Result.map_error (fun message -> Unavailable message) in
    Ok (source, request))

let save ~base_path ~author (request : request) =
  if String.trim author = "" || not (String.is_valid_utf_8 author)
  then Error (Invalid "author must be a nonblank UTF-8 string")
  else protect (fun () ->
    let dir = root ~base_path in
    let* _ = directory ~base_path in
    let* () = match Keeper_fs_durable_directory.ensure
      ~before_prepare:(fun () -> ()) ~before_directory_fsync:(fun _ -> ())
      ~ownership_root:base_path dir with
      | Ok _ -> Ok ()
      | Error _ -> Error (Unavailable "project source directory could not be prepared") in
    let* _ = directory ~base_path in
    let id = Random_id.prefixed ~prefix:"project-" ~bytes:16 in
    match File_lock_eio.with_durable_lock_observed
      ~lock_path:(Filename.concat dir (id ^ ".lock")) (fun () ->
        let* () = match load ~base_path id with
          | Error Missing -> Ok ()
          | Ok _ -> Error (Unavailable "generated project source id already exists")
          | Error ((Invalid _ | Unavailable _ | Commit_uncertain _) as error) -> Error error in
        let blobs = Tool_blob_store.create ~base_path in
        let files = List.map (fun (file : file) ->
          let body = Tool_blob_store.put_durable blobs ~bytes:file.content
            ~mime:"application/octet-stream" in
          { path = file.path; body }) request.files in
        let source = { id; author; created_at = Types_core.now_iso ();
          build = request.build; install_scripts = request.install_scripts; files } in
        match Keeper_fs.save_json_durable_atomic ~ownership_root:base_path
          (path ~base_path id) (Artifact_project_source.to_json source) with
        | Ok () -> Ok source
        | Error error ->
          let message = Keeper_fs.durable_write_error_to_string error in
          Error (if error.renamed then Commit_uncertain { id; message } else Unavailable message)) with
    | File_lock_eio.Lock_not_acquired error ->
      Error (Unavailable (File_lock_eio.durable_lock_error_to_string error))
    | File_lock_eio.Body_completed { value; release_error = None } -> value
    | File_lock_eio.Body_completed { value; release_error = Some error } ->
      Log.Misc.error "project source lock release: %s"
        (File_lock_eio.durable_lock_error_to_string error);
      value)
