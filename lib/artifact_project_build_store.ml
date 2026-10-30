open Artifact_project_build
type error =
  | Invalid of string
  | Missing
  | Source_error of Artifact_project_source_store.error
  | Unavailable of string
  | Commit_uncertain of { id : string; message : string }
type file = { path : string; body : Tool_output.artifact_ref; content : string }
let error_message = function
  | Invalid message | Unavailable message | Commit_uncertain { message; _ } -> message
  | Missing -> "project build or file not found"
  | Source_error error -> Artifact_project_source_store.error_message error
open Result.Syntax
let root ~base_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "artifact_project_builds"
let path ~base_path id = Filename.concat (root ~base_path) (id ^ ".json")
let protect f = try f () with
  | Sys_error message -> Error (Unavailable message)
  | Unix.Unix_error (error, operation, _) -> Error (Unavailable (operation ^ ": " ^ Unix.error_message error))
let directory ~base_path =
  Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.geteuid ()) ~ownership_root:base_path (root ~base_path)
  |> Result.map_error (fun error -> Unavailable (Fs_compat.owned_regular_file_read_error_to_string error))
let load ~base_path id =
  match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
    ~ownership_root:base_path (path ~base_path id) with
  | Error error -> Error (Unavailable (Fs_compat.owned_regular_file_read_error_to_string error))
  | Ok None -> Error Missing
  | Ok (Some { snapshot; _ }) when snapshot.permissions <> 0o600 -> Error (Unavailable "build metadata must be private read/write")
  | Ok (Some { content; _ }) when not (String.is_valid_utf_8 content) -> Error (Unavailable "build metadata is not UTF-8")
  | Ok (Some { content; _ }) ->
    (match Yojson.Safe.from_string content with
     | json ->
       let* build = Artifact_project_build.of_json json |> Result.map_error (fun message -> Unavailable message) in
       if String.equal build.id id then Ok build else Error (Unavailable "build identity mismatch")
     | exception Yojson.Json_error message -> Error (Unavailable message))
let source_error error = Source_error error
let read_with_source ~base_path ~id =
  if not (valid_id id) then Error (Invalid "invalid build id")
  else protect (fun () ->
    let* entries = directory ~base_path in
    let* () = match entries with None -> Error Missing | Some _ -> Ok () in
    let* build = load ~base_path id in
    let* source = Artifact_project_source_store.read_metadata ~base_path ~id:build.source_id |> Result.map_error source_error in
    let* () = validate_source ~digest:(fun (body : Tool_output.artifact_ref) -> body.sha256) ~source build.receipt
      |> Result.map_error (fun message -> Unavailable message) in
    Ok (build, source))
let read ~base_path ~id = let* build, _ = read_with_source ~base_path ~id in Ok build
let fetch blobs (body : Tool_output.artifact_ref) =
  match Tool_blob_store.fetch blobs ~sha256:body.sha256 with
  | Ok (Some content) when String.length content = body.bytes -> Ok content
  | Ok (Some _) -> Error (Unavailable "build payload length mismatch")
  | Ok None -> Error (Unavailable "build payload is missing")
  | Error error -> Error (Unavailable (Tool_blob_store.fetch_error_to_string error))
let restore ~base_path ~id = protect (fun () ->
  let* build = read ~base_path ~id in
  let blobs = Tool_blob_store.create ~base_path in
  let* receipt = map_bodies (fun ~mime:_ body -> fetch blobs body) build.receipt in
  (* Reuse the authoritative worker decoder after payload retrieval. *)
  Artifact_project_build.input_of_receipt receipt |> Result.map_error (fun message -> Unavailable message))

let read_file ~base_path ~id ~path:requested = protect (fun () ->
  let* requested = match requested with None -> Ok None | Some path ->
    Artifact_project_source.relative_path path |> Result.map Option.some |> Result.map_error (fun message -> Invalid message) in
  let* build, source = read_with_source ~base_path ~id in
  let* entry, files = match build.receipt.output, source.Artifact_project_source.build with
    | Html body, Artifact_project_source.Browser_modules { entry_html } -> Ok (entry_html, [entry_html, body])
    | Site site, Artifact_project_source.Package_script _ ->
      Ok (site.entry_html, List.map (fun (file : Tool_output.artifact_ref Artifact_project_build.file) -> file.path, file.body) site.files)
    | Html _, Artifact_project_source.Package_script _ | Site _, Artifact_project_source.Browser_modules _ ->
      Error (Unavailable "stored source and output selection mismatch") in
  let selected = Option.value ~default:entry requested in
  let* body = match List.assoc_opt selected files with Some body -> Ok body | None -> Error Missing in
  let* content = fetch (Tool_blob_store.create ~base_path) body in
  if String.equal selected entry && not (String.is_valid_utf_8 content)
  then Error (Unavailable "build HTML entry is not UTF-8")
  else Ok (build, { path = selected; body; content }))

let save ~base_path ~source_id ~author (input : input) =
  if String.trim author = "" || not (String.is_valid_utf_8 author) || String.contains author '\000'
  then Error (Invalid "author must be nonblank UTF-8 without NUL")
  else protect (fun () ->
    let* source, _ = Artifact_project_source_store.read ~base_path ~id:source_id |> Result.map_error source_error in
    let* () = validate_source ~digest:(fun bytes -> Agent_core_sha256.(digest_string bytes |> to_hex)) ~source input.receipt
      |> Result.map_error (fun message -> Invalid message) in
    let dir = root ~base_path in
    let* _ = directory ~base_path in
    let* () = match Keeper_fs_durable_directory.ensure ~ownership_root:base_path
      ~before_prepare:(fun () -> ()) ~before_directory_fsync:(fun _ -> ()) dir with
      | Ok _ -> Ok () | Error _ -> Error (Unavailable "build directory could not be prepared") in
    let* _ = directory ~base_path in
    let id = Random_id.prefixed ~prefix:"build-" ~bytes:16 in
    match File_lock_eio.with_durable_lock_observed ~lock_path:(Filename.concat dir (id ^ ".lock")) (fun () ->
      let* () = match load ~base_path id with
        | Error Missing -> Ok () | Ok _ -> Error (Unavailable "generated build id already exists")
        | Error ((Invalid _ | Source_error _ | Unavailable _ | Commit_uncertain _) as error) -> Error error in
      let blobs = Tool_blob_store.create ~base_path in
      let* receipt = map_bodies (fun ~mime content -> Ok (Tool_blob_store.put_durable blobs ~bytes:content ~mime)) input.receipt in
      let build = { id; source_id; author; created_at = Types_core.now_iso (); receipt } in
      match Keeper_fs.save_json_durable_atomic ~ownership_root:base_path (path ~base_path id) (Artifact_project_build.to_json build) with
      | Ok () -> Ok build
      | Error error ->
        let message = Keeper_fs.durable_write_error_to_string error in
        Error (if error.renamed then Commit_uncertain { id; message } else Unavailable message)) with
    | File_lock_eio.Lock_not_acquired error -> Error (Unavailable (File_lock_eio.durable_lock_error_to_string error))
    | File_lock_eio.Body_completed { value; release_error = None } -> value
    | File_lock_eio.Body_completed { value; release_error = Some error } ->
      Log.Misc.error "build publication lock release: %s" (File_lock_eio.durable_lock_error_to_string error); value)
