type build =
  | Browser_modules of { entry_html : string }
  | Package_script of { script : string; output_directory : string; entry_html : string }
type file = { path : string; content : string }
type request = { build : build; install_scripts : bool; files : file list }
type stored_file = { path : string; body : Tool_output.artifact_ref }
type t =
  { id : string; author : string; created_at : string; build : build
  ; install_scripts : bool; files : stored_file list }

open Result.Syntax
let valid_id id =
  String.length id = 40 && String.starts_with ~prefix:"project-" id
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       (String.sub id 8 32)

let object_fields allowed = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.sort String.compare names = List.sort String.compare allowed
    then Ok fields else Error "unexpected, duplicate or missing project fields"
  | _ -> Error "expected a project object"
let value name fields = Option.value ~default:`Null (List.assoc_opt name fields)
let text name fields = match value name fields with
  | `String text when String.is_valid_utf_8 text -> Ok text
  | _ -> Error (name ^ " must be a UTF-8 string")
let nonblank name fields =
  let* text = text name fields in
  if String.trim text = "" then Error (name ^ " must be nonblank") else Ok text
let boolean name fields = match value name fields with
  | `Bool flag -> Ok flag | _ -> Error (name ^ " must be a boolean")
let schema expected fields = match value "schema" fields with
  | `String actual when String.equal actual expected -> Ok ()
  | _ -> Error "unknown project schema"
let traverse decode = function
  | `List items ->
    let* reversed = List.fold_left (fun acc item ->
      let* acc = acc in let* item = decode item in Ok (item :: acc)) (Ok []) items in
    Ok (List.rev reversed)
  | _ -> Error "files must be an array"

let relative_path path =
  let components = String.split_on_char '/' path in
  let drive = String.length path >= 2 && path.[1] = ':'
    && (match path.[0] with 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false) in
  if not (String.is_valid_utf_8 path) || drive || String.contains path '\\' || String.contains path '\000'
     || List.exists (fun part -> part = "" || part = "." || part = "..") components
  then Error "expected a relative project path without traversal"
  else Ok path
let path name fields = let* path = text name fields in relative_path path
let source_path fields =
  let* path = path "path" fields in
  if List.exists (fun part -> part = "node_modules" || part = ".git")
    (String.split_on_char '/' path)
  then Error "dependency and Git directories are not source uploads"
  else Ok path

module Paths = Set.Make (String)
let validate_paths build paths =
  let set = List.fold_left (fun set path -> Paths.add path set) Paths.empty paths in
  if Paths.cardinal set <> List.length paths then Error "duplicate project path"
  else if not (Paths.mem "package.json" set) then Error "project must contain package.json"
  else
    let rec ancestors path =
      let parent = Filename.dirname path in
      parent <> "." && (Paths.mem parent set || ancestors parent) in
    if List.exists ancestors paths then Error "a project file is also used as a directory"
    else match build with
      | Browser_modules { entry_html } when not (Paths.mem entry_html set) ->
        Error "project must contain entry HTML"
      | Browser_modules _ | Package_script _ -> Ok ()

let build_of_json json =
  let* kind = match json with
    | `Assoc fields -> text "kind" fields
    | _ -> Error "expected a build selection" in
  match kind with
  | "browser_modules" ->
    let* fields = object_fields ["kind"; "entry_html"] json in
    let* entry_html = path "entry_html" fields in Ok (Browser_modules { entry_html })
  | "package_script" ->
    let* fields = object_fields ["kind"; "script"; "output_directory"; "entry_html"] json in
    let* script = text "script" fields in
    let* () = if script = "" || String.contains script '\000'
      then Error "expected an exact package script name" else Ok () in
    let* output_directory = path "output_directory" fields in
    let* entry_html = path "entry_html" fields in
    Ok (Package_script { script; output_directory; entry_html })
  | _ -> Error "unknown build kind"
let build_to_json = function
  | Browser_modules { entry_html } ->
    `Assoc ["kind", `String "browser_modules"; "entry_html", `String entry_html]
  | Package_script { script; output_directory; entry_html } ->
    `Assoc ["kind", `String "package_script"; "script", `String script;
            "output_directory", `String output_directory; "entry_html", `String entry_html]

let request_of_json json =
  let* fields = object_fields ["schema"; "build"; "install_scripts"; "files"] json in
  let* () = schema "masc.artifact_project.v1" fields in
  let* build = build_of_json (value "build" fields) in
  let* install_scripts = boolean "install_scripts" fields in
  let* files = traverse (fun json ->
    let* fields = object_fields ["path"; "content_base64"] json in
    let* path = source_path fields in
    let* encoded = text "content_base64" fields in
    match Base64.decode encoded with
    | Ok content when String.equal (Base64.encode_string content) encoded ->
      Ok ({ path; content } : file)
    | Ok _ | Error _ -> Error "expected canonical base64 file bytes") (value "files" fields) in
  let* () = validate_paths build (List.map (fun (file : file) -> file.path) files) in
  Ok { build; install_scripts; files }
let request_to_json (request : request) =
  `Assoc ["schema", `String "masc.artifact_project.v1";
          "build", build_to_json request.build; "install_scripts", `Bool request.install_scripts;
          "files", `List (List.map (fun (file : file) ->
            `Assoc ["path", `String file.path;
                    "content_base64", `String (Base64.encode_string file.content)]) request.files)]

let to_json (source : t) =
  `Assoc ["schema", `String "masc.artifact_project_source.v1";
          "id", `String source.id; "author", `String source.author;
          "created_at", `String source.created_at; "build", build_to_json source.build;
          "install_scripts", `Bool source.install_scripts;
          "files", `List (List.map (fun (file : stored_file) ->
            `Assoc ["path", `String file.path;
                    "body", Tool_output.normalized_artifact_ref_to_json file.body]) source.files)]
let of_json json =
  let* fields = object_fields ["schema"; "id"; "author"; "created_at"; "build"; "install_scripts"; "files"] json in
  let* () = schema "masc.artifact_project_source.v1" fields in
  let* id = nonblank "id" fields in
  let* () = if valid_id id then Ok () else Error "invalid project source id" in
  let* author = nonblank "author" fields in
  let* created_at = nonblank "created_at" fields in
  let* build = build_of_json (value "build" fields) in
  let* install_scripts = boolean "install_scripts" fields in
  let* files = traverse (fun json ->
    let* fields = object_fields ["path"; "body"] json in
    let* path = source_path fields in
    match Tool_output.normalized_artifact_ref_of_json (value "body" fields) with
    | Tool_output.Decoded_normalized_artifact_ref body
      when String.equal body.mime "application/octet-stream"
           && String.is_valid_utf_8 body.preview -> Ok { path; body }
    | Tool_output.Decoded_normalized_artifact_ref _
    | Tool_output.Not_normalized_artifact_ref
    | Tool_output.Invalid_normalized_artifact_ref _ -> Error "invalid project file reference")
    (value "files" fields) in
  let* () = validate_paths build (List.map (fun (file : stored_file) -> file.path) files) in
  Ok { id; author; created_at; build; install_scripts; files }
