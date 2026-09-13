module Store = Workspace_memory_proposal
let ( let* ) = Result.bind

type descriptor = { proposal_id : string; context_sha256 : string }
type observation = Missing | Available of descriptor | Unavailable of string

let directory ~base_path =
  Filename.concat (Filename.concat base_path Common.masc_dirname) "workspace-memory"
let path ~base_path = Filename.concat (directory ~base_path) "publication.json"
let store_error = function Store.Invalid detail | Store.Unavailable detail -> detail
let io f = try f () with
  | Unix.Unix_error (error, fn, arg) ->
    Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error))
  | Sys_error detail -> Error detail
  | Eio.Io _ as exn -> Error (Printexc.to_string exn)

let descriptor_of_proposal ~proposal_id proposal =
  match Yojson.Safe.Util.member "context_sha256" (Store.to_json proposal) with
  | `String context_sha256 -> Ok { proposal_id; context_sha256 }
  | _ -> Error "Validated proposal has no context fingerprint"

let resolve ~base_path ~proposal_id =
  let* proposal = Store.read ~base_path ~id:proposal_id |> Result.map_error store_error in
  match proposal with
  | None -> Error "Published workspace memory proposal is missing"
  | Some proposal -> descriptor_of_proposal ~proposal_id proposal

let decode = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
       = ["context_sha256"; "proposal_id"; "schema"] ->
    (match List.assoc "schema" fields, List.assoc "proposal_id" fields,
           List.assoc "context_sha256" fields with
     | `String "workspace.memory.publication.v1", `String proposal_id, `String context_sha256 ->
       Ok { proposal_id; context_sha256 }
     | _ -> Error "Invalid workspace memory publication descriptor")
  | _ -> Error "Invalid workspace memory publication descriptor fields"

let present_directory path =
  match (try Some (Unix.lstat path).Unix.st_kind with
         | Unix.Unix_error (Unix.ENOENT, _, _) -> None) with
  | None -> Ok false
  | Some _ ->
    (* Follow intentional directory aliases, but retain dangling-link and
       non-directory failures rather than reporting missing publication. *)
    if (Unix.stat path).Unix.st_kind = Unix.S_DIR then Ok true
    else Error (path ^ ": not a directory")

let publication_directory_present ~base_path =
  let* base_present = present_directory base_path in
  if not base_present then Error "Workspace base directory is missing" else
  let* runtime_present = present_directory (Filename.concat base_path Common.masc_dirname) in
  if not runtime_present then Ok false else present_directory (directory ~base_path)

let read ~base_path = io (fun () ->
  let* present = publication_directory_present ~base_path in
  if not present then Ok None else
  let path = path ~base_path in
  let kind = try Some (Unix.lstat path).Unix.st_kind with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> None in
  match kind with
  | None -> Ok None
  | Some Unix.S_REG ->
    let* json = try Ok (Yojson.Safe.from_string (Fs_compat.load_file path)) with
      | Yojson.Json_error detail -> Error detail in
    let* expected = decode json in
    let* actual = resolve ~base_path ~proposal_id:expected.proposal_id in
    if actual = expected then Ok (Some actual)
    else Error "Publication context fingerprint differs from its saved proposal"
  | Some _ -> Error "Workspace memory publication descriptor is not a regular file")

let observe ~base_path = match read ~base_path with
  | Ok None -> Missing
  | Ok (Some descriptor) -> Available descriptor
  | Error detail -> Unavailable detail

let publish ~base_path ~proposal_id =
  let* descriptor = resolve ~base_path ~proposal_id in
  let* previous = read ~base_path in
  match previous with
  | Some previous when previous = descriptor -> Ok ()
  | _ -> io (fun () ->
    Fs_compat.mkdir_p (directory ~base_path);
    let json = `Assoc ["schema", `String "workspace.memory.publication.v1";
      "proposal_id", `String descriptor.proposal_id;
      "context_sha256", `String descriptor.context_sha256] in
    let* () = match Fs_compat.save_file_atomic_strict_staged (path ~base_path) (Yojson.Safe.to_string json) with
      | Ok () -> Ok ()
      | Error failure ->
        (match failure.exception_ with
         | Eio.Cancel.Cancelled _ as exn -> Printexc.raise_with_backtrace exn failure.backtrace
         | _ -> Error (Fs_compat.atomic_replace_failure_to_string failure)) in
    let* saved = read ~base_path in
    match saved with
    | Some saved when saved = descriptor -> Ok ()
    | _ -> Error "Workspace memory publication changed during readback")
