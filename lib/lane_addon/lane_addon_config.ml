type declaration = {
  id : string;
  run_id : string;
  manifest_path : string;
  package : Lane_addon_types.package;
  binding : Yojson.Safe.t;
  revision : string;
  source_path : string;
}

type issue = { source_path : string; id : string option; message : string }
type snapshot = {
  declarations : declaration list;
  issues : issue list;
  paths : string list;
  complete : bool;
}

type failure = { issue : issue; unreadable : bool }
let ( let* ) = Result.bind

let absolute_from ~directory path =
  if Filename.is_relative path then Filename.concat directory path else path

let absolute path = absolute_from ~directory:(Sys.getcwd ()) path

let io_message = function
  | Sys_error message -> message
  | Unix.Unix_error (error, call, arg) ->
      call ^ " " ^ arg ^ ": " ^ Unix.error_message error
  | End_of_file -> "declaration changed while reading"
  | exn -> raise exn

let read_document path =
  try
    let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC] 0 in
    let channel = Unix.in_channel_of_descr fd in
    Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      let before = Unix.fstat fd in
      if before.Unix.st_kind <> Unix.S_REG then
        Error "declaration must be a regular file"
      else
        let bytes = really_input_string channel before.Unix.st_size in
        let after = Unix.fstat fd in
        if before.Unix.st_size <> after.Unix.st_size
           || before.Unix.st_mtime <> after.Unix.st_mtime
           || before.Unix.st_ctime <> after.Unix.st_ctime
        then Error "declaration changed while reading"
        else Ok bytes)
  with (Sys_error _ | Unix.Unix_error _ | End_of_file) as exn -> Error (io_message exn)

let rec json_of_toml ~path : Otoml.t -> (Yojson.Safe.t, string) result = function
  | Otoml.TomlString value -> Ok (`String value)
  | Otoml.TomlInteger value -> Ok (`Int value)
  | Otoml.TomlBoolean value -> Ok (`Bool value)
  | Otoml.TomlFloat value when Float.is_finite value -> Ok (`Float value)
  | Otoml.TomlFloat _ -> Error (path ^ ": non-finite numbers are not supported")
  | Otoml.TomlArray values | Otoml.TomlTableArray values ->
      let rec loop index acc = function
        | [] -> Ok (`List (List.rev acc))
        | value :: rest ->
            let* value = json_of_toml ~path:(Printf.sprintf "%s[%d]" path index) value in
            loop (index + 1) (value :: acc) rest
      in
      loop 0 [] values
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
      let rec loop acc = function
        | [] -> Ok (`Assoc (List.rev acc))
        | (key, value) :: rest ->
            let* value = json_of_toml ~path:(path ^ "." ^ key) value in
            loop ((key, value) :: acc) rest
      in
      loop [] fields
  | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ ->
      Error (path ^ ": TOML date/time values are unsupported; use an explicit string")

let text fields key =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlString value) when String.trim value <> "" -> Ok value
  | _ -> Error (key ^ " requires a non-blank string")

let resolve_snapshot_paths ~directory = function
  | `Assoc fields ->
      let resolve = function
        | `Assoc source ->
            (match List.assoc_opt "kind" source, List.assoc_opt "path" source with
             | Some (`String "snapshot_file"), Some (`String path)
               when String.trim path <> "" ->
                 `Assoc (("path", `String (absolute_from ~directory path))
                   :: List.remove_assoc "path" source)
             | _ -> `Assoc source)
        | value -> value
      in
      (match List.assoc_opt "sources" fields with
       | Some (`List sources) ->
           `Assoc (("sources", `List (List.map resolve sources))
             :: List.remove_assoc "sources" fields)
       | _ -> `Assoc fields)
  | value -> value

let decode ~source_path ~id fields =
  let allowed = ["id"; "run_id"; "manifest_path"; "binding"] in
  let* () = match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
    | None -> Ok () | Some (key, _) -> Error ("unknown declaration field: " ^ key) in
  let* run_id = text fields "run_id" in
  let* manifest_path = text fields "manifest_path" in
  let directory = Filename.dirname source_path in
  let manifest_path = absolute_from ~directory manifest_path in
  let* package = Lane_addon_manifest.load ~path:manifest_path in
  let* binding = match List.assoc_opt "binding" fields with
    | Some (Otoml.TomlTable _ | Otoml.TomlInlineTable _ as value) ->
        json_of_toml ~path:"binding" value
    | _ -> Error "binding requires a table" in
  let binding = resolve_snapshot_paths ~directory binding in
  let* () = Lane_addon_sources.validate binding in
  let manifest_path = Unix.realpath manifest_path in
  let canonical =
    `Assoc ["id", `String id; "run_id", `String run_id;
      "manifest_path", `String manifest_path;
      "package", Lane_addon_types.package_to_json package; "binding", binding]
    |> Yojson.Safe.sort |> Yojson.Safe.to_string
  in
  let revision = Digestif.SHA256.(to_hex (digest_string canonical)) in
  Ok { id; run_id; manifest_path; package; binding; revision; source_path }

let parse_declaration ~source_path bytes =
  let failure ?id ~unreadable message =
    Error { issue = {source_path; id; message}; unreadable } in
  try
      (match Otoml.Parser.from_string_result bytes with
       | Error message -> failure ~unreadable:false message
       | Ok (Otoml.TomlTable fields) ->
           (match text fields "id" with
            | Error message -> failure ~unreadable:false message
            | Ok id ->
                try
                  match decode ~source_path ~id fields with
                  | Ok declaration -> Ok declaration
                  | Error message -> failure ~id ~unreadable:false message
                with (Sys_error _ | Unix.Unix_error _) as exn ->
                  failure ~id ~unreadable:true (io_message exn))
       | Ok _ -> failure ~unreadable:false "declaration requires a TOML table")
  with Otoml.Duplicate_key message -> failure ~unreadable:false message

let load_source ~source_path ~source_text =
  parse_declaration ~source_path:(absolute source_path) source_text
  |> Result.map_error (fun failure -> failure.issue.message)

let read_declaration ~path =
  let source_path = absolute path in
  match read_document source_path with
  | Error message -> Error {issue={source_path;id=None;message};unreadable=true}
  | Ok bytes -> parse_declaration ~source_path bytes

let load_file ~path =
  read_declaration ~path |> Result.map_error (fun failure -> failure.issue.message)

let load ~directory =
  let directory = absolute directory in
  let listing = try
    Ok (Sys.readdir directory |> Array.to_list
      |> List.filter (fun name -> Filename.check_suffix name ".toml")
      |> List.sort String.compare
      |> List.map (Filename.concat directory))
  with
  | Sys_error message ->
      (* [Sys.readdir] loses the errno. [stat] distinguishes a missing directory
         from a failed directory read; neither an empty default nor a string
         match may authorize removal of an existing installation. *)
      (match (Unix.stat directory).Unix.st_kind with
       | Unix.S_DIR -> Error message
       | _ -> Error "configuration path is not a directory"
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
       | exception Unix.Unix_error _ -> Error message)
  in
  match listing with
  | Error message ->
      { declarations = []; issues = [{source_path = directory; id = None; message}];
        paths = []; complete = false }
  | Ok paths ->
      let results = List.map (fun path -> path, read_declaration ~path) paths in
      let id_of_result = function
        | Ok (declaration : declaration) -> Some declaration.id
        | Error failure -> failure.issue.id in
      let ids = List.filter_map (fun (_, result) -> id_of_result result) results in
      let duplicates = ids |> List.sort String.compare |> List.fold_left
        (fun (previous, duplicates) id ->
           if previous = Some id then Some id, id :: duplicates
           else Some id, duplicates) (None, []) |> snd |> List.sort_uniq String.compare in
      let declarations, issues, complete = List.fold_left
        (fun (declarations, issues, complete) (source_path, result) ->
           let id = id_of_result result in
           let duplicate = Option.exists (fun id -> List.mem id duplicates) id in
           let issues = if duplicate then
               {source_path; id; message = "duplicate declaration id"} :: issues else issues in
           match result with
           | Ok declaration when not duplicate -> declaration :: declarations, issues, complete
           | Ok _ -> declarations, issues, complete
           | Error failure -> declarations, failure.issue :: issues,
               complete && not failure.unreadable)
        ([], [], true) results in
      {declarations = List.rev declarations; issues = List.rev issues; paths; complete}
