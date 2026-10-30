type runtime = { node : string; platform : string; arch : string }
type lock_source = Supplied | Resolved
type lockfile = Package_lock | Shrinkwrap
type 'body install = { scripts : bool; lock_source : lock_source; lockfile : lockfile; lock : 'body }
type source_file = { path : string; sha256 : string }
type build =
  | Browser_modules of
      { entry_html : string; esbuild : string; inputs : string list; warnings : string list; external_resources : string list }
  | Package_script of { script : string; output_directory : string; entry_html : string }
type 'body file = { path : string; body : 'body }
type 'body output = Html of 'body | Site of { entry_html : string; sha256 : string; files : 'body file list }
type 'body receipt =
  { runtime : runtime; run_directory : string; source_files : source_file list
  ; install : 'body install; build : build; output : 'body output }
type input = { receipt : string receipt }
type t =
  { id : string; source_id : string; author : string; created_at : string
  ; receipt : Tool_output.artifact_ref receipt }

open Result.Syntax
let digest bytes = Agent_core_sha256.(digest_string bytes |> to_hex)
let valid_id id = String.length id = 38 && String.starts_with ~prefix:"build-" id
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) (String.sub id 6 32)
let object_fields allowed = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare allowed -> Ok fields
  | _ -> Error "unexpected, duplicate or missing build fields"
let value name fields = Option.value ~default:`Null (List.assoc_opt name fields)
let text name fields = match value name fields with
  | `String value when String.is_valid_utf_8 value -> Ok value
  | _ -> Error (name ^ " must be a UTF-8 string")
let nonblank name fields = let* text = text name fields in
  if String.trim text = "" || String.contains text '\000' then Error (name ^ " must be nonblank without NUL") else Ok text
let path name fields = let* path = text name fields in Artifact_project_source.relative_path path
let bool name fields = match value name fields with `Bool value -> Ok value | _ -> Error (name ^ " must be boolean")
let exact name expected fields = match value name fields with
  | `String actual when String.equal actual expected -> Ok () | _ -> Error ("invalid " ^ name)
let sha name fields =
  let* sha = text name fields in
  let* () = Tool_output.validate_sha256 sha |> Result.map_error Tool_output.invalid_sha256_to_string in Ok sha
let traverse decode = function
  | `List items ->
    let* reversed = List.fold_left (fun acc item -> let* acc = acc in let* item = decode item in Ok (item :: acc)) (Ok []) items in
    Ok (List.rev reversed)
  | _ -> Error "expected an array"
let strings json = traverse (function `String text when String.is_valid_utf_8 text -> Ok text
  | _ -> Error "expected UTF-8 strings") json
module Paths = Set.Make (String)
let unique_paths paths =
  let set = Paths.of_list paths in
  let rec ancestor path = let parent = Filename.dirname path in
    parent <> "." && (Paths.mem parent set || ancestor parent) in
  if Paths.cardinal set <> List.length paths || List.exists ancestor paths
  then Error "duplicate or overlapping build file paths" else Ok ()
let lockfile_name = function Package_lock -> "package-lock.json" | Shrinkwrap -> "npm-shrinkwrap.json"
let lock_source_name = function Supplied -> "supplied" | Resolved -> "resolved"
let install_of_json ~keys ~lock json =
  let* fields = object_fields (["mode"; "scripts"; "lock_source"; "lockfile"] @ keys) json in
  let* () = exact "mode" "ci" fields in
  let* scripts = bool "scripts" fields in
  let* lock_source = match value "lock_source" fields with
    | `String "supplied" -> Ok Supplied | `String "resolved" -> Ok Resolved | _ -> Error "unknown lock source" in
  let* lockfile = match value "lockfile" fields with
    | `String "package-lock.json" -> Ok Package_lock | `String "npm-shrinkwrap.json" -> Ok Shrinkwrap
    | _ -> Error "unknown lockfile" in
  let* lock = lock fields in Ok { scripts; lock_source; lockfile; lock }
let install_to_json ~lock (install : 'a install) =
  `Assoc (["mode", `String "ci"; "scripts", `Bool install.scripts;
           "lock_source", `String (lock_source_name install.lock_source);
           "lockfile", `String (lockfile_name install.lockfile)] @ lock install.lock)
let build_of_json json =
  match json with
  | `Assoc fields when value "kind" fields = `String "browser_modules" ->
    let* fields = object_fields ["kind"; "entry_html"; "esbuild"; "inputs"; "warnings"; "external_resources"] json in
    let* entry_html = path "entry_html" fields in
    let* esbuild = nonblank "esbuild" fields in
    let* inputs = strings (value "inputs" fields) in
    let* warnings = strings (value "warnings" fields) in
    let* external_resources = strings (value "external_resources" fields) in
    Ok (Browser_modules { entry_html; esbuild; inputs; warnings; external_resources })
  | _ ->
    let* build = Artifact_project_source.build_of_json json in
    (match build with
     | Artifact_project_source.Package_script { script; output_directory; entry_html } ->
       Ok (Package_script { script; output_directory; entry_html })
     | Artifact_project_source.Browser_modules _ -> Error "missing browser build evidence")
let build_to_json = function
  | Browser_modules { entry_html; esbuild; inputs; warnings; external_resources } ->
    let strings values = `List (List.map (fun text -> `String text) values) in
    `Assoc ["kind", `String "browser_modules"; "entry_html", `String entry_html; "esbuild", `String esbuild;
            "inputs", strings inputs; "warnings", strings warnings; "external_resources", strings external_resources]
  | Package_script { script; output_directory; entry_html } ->
    Artifact_project_source.build_to_json (Artifact_project_source.Package_script { script; output_directory; entry_html })
let site_digest ~identity ~entry_html files =
  let files = List.map (fun file -> let sha256, bytes = identity file.body in
    `Assoc ["path", `String file.path; "bytes", `Int bytes; "sha256", `String sha256]) files in
  digest (Yojson.Safe.to_string (`Assoc ["entry_html", `String entry_html; "files", `List files]))
let output_of_json ~identity ~html ~file json =
  match json with
  | `Assoc fields when value "kind" fields = `String "html" ->
    let* fields = object_fields ["kind"; "artifact"] json in
    let* body = html (value "artifact" fields) in Ok (Html body)
  | `Assoc fields when value "kind" fields = `String "site" ->
    let* fields = object_fields ["kind"; "entry_html"; "sha256"; "files"] json in
    let* entry_html = path "entry_html" fields in
    let* sha256 = sha "sha256" fields in
    let* files = traverse file (value "files" fields) in
    let* () = unique_paths (List.map (fun file -> file.path) files) in
    if not (List.exists (fun file -> String.equal file.path entry_html) files)
    then Error "site entry is missing"
    else if not (String.equal sha256 (site_digest ~identity ~entry_html files))
    then Error "site manifest digest mismatch"
    else Ok (Site { entry_html; sha256; files })
  | _ -> Error "unknown build output kind"
let output_to_json ~html ~file = function
  | Html body -> `Assoc ["kind", `String "html"; "artifact", html body]
  | Site { entry_html; sha256; files } ->
    `Assoc ["kind", `String "site"; "entry_html", `String entry_html; "sha256", `String sha256;
            "files", `List (List.map file files)]
let receipt_of_json ~schema ~install ~output json =
  let* fields = object_fields ["schema"; "runtime"; "run_directory"; "source_files"; "install"; "build"; "output"] json in
  let* () = exact "schema" schema fields in
  let* runtime =
    let* fields = object_fields ["node"; "platform"; "arch"] (value "runtime" fields) in
    let* node = nonblank "node" fields in let* platform = nonblank "platform" fields in
    let* arch = nonblank "arch" fields in Ok { node; platform; arch } in
  let* run_directory = nonblank "run_directory" fields in
  let* source_files = traverse (fun json ->
    let* fields = object_fields ["path"; "sha256"] json in
    let* path = path "path" fields in let* sha256 = sha "sha256" fields in
    Ok ({ path; sha256 } : source_file)) (value "source_files" fields) in
  let* () = unique_paths (List.map (fun (file : source_file) -> file.path) source_files) in
  let* install = install (value "install" fields) in
  let* build = build_of_json (value "build" fields) in
  let* output = output (value "output" fields) in
  let* () = match build, output with
    | Browser_modules _, Html _ -> Ok ()
    | Package_script build, Site site when String.equal build.entry_html site.entry_html -> Ok ()
    | Browser_modules _, Site _ | Package_script _, Html _ | Package_script _, Site _ ->
      Error "build and output selection mismatch" in
  Ok { runtime; run_directory; source_files; install; build; output }
let receipt_to_json ~schema ~install ~output (receipt : 'a receipt) =
  `Assoc ["schema", `String schema;
          "runtime", `Assoc ["node", `String receipt.runtime.node; "platform", `String receipt.runtime.platform; "arch", `String receipt.runtime.arch];
          "run_directory", `String receipt.run_directory;
          "source_files", `List (List.map (fun (file : source_file) -> `Assoc ["path", `String file.path; "sha256", `String file.sha256]) receipt.source_files);
          "install", install receipt.install; "build", build_to_json receipt.build; "output", output receipt.output]

let string_identity bytes = digest bytes, String.length bytes
let ref_identity (body : Tool_output.artifact_ref) = body.sha256, body.bytes
let verify_digest content fields =
  let* sha = sha "sha256" fields in
  if String.equal sha (digest content) then Ok content else Error "payload digest mismatch"
let worker_output = output_of_json ~identity:string_identity
  ~html:(fun json ->
    let* fields = object_fields ["format"; "content"; "sha256"] json in
    let* () = exact "format" "html" fields in
    let* content = text "content" fields in verify_digest content fields)
  ~file:(fun json ->
    let* fields = object_fields ["path"; "bytes"; "sha256"; "content_base64"] json in
    let* path = path "path" fields in
    let* encoded = text "content_base64" fields in
    let* content = match Base64.decode encoded with
      | Ok content when String.equal (Base64.encode_string content) encoded -> Ok content
      | Ok _ | Error _ -> Error "noncanonical build file base64" in
    let* body = verify_digest content fields in
    if value "bytes" fields = `Int (String.length body) then Ok { path; body }
    else Error "build file length mismatch")
let worker_output_json = output_to_json
  ~html:(fun content -> `Assoc ["format", `String "html"; "content", `String content; "sha256", `String (digest content)])
  ~file:(fun file -> `Assoc ["path", `String file.path; "bytes", `Int (String.length file.body);
    "sha256", `String (digest file.body); "content_base64", `String (Base64.encode_string file.body)])
let worker_install = install_of_json ~keys:["lock_content"; "lock_sha256"] ~lock:(fun fields ->
  let* content = text "lock_content" fields in let* sha = sha "lock_sha256" fields in
  if String.equal sha (digest content) then Ok content else Error "lock digest mismatch")
let worker_install_json = install_to_json ~lock:(fun content ->
  ["lock_content", `String content; "lock_sha256", `String (digest content)])
let input_of_json json =
  let* receipt = receipt_of_json ~schema:"masc.artifact_project_result.v1" ~install:worker_install ~output:worker_output json in
  let* () = match receipt.output with
    | Html _ -> Ok ()
    | Site site ->
      if List.exists (fun file -> String.equal file.path site.entry_html && String.is_valid_utf_8 file.body) site.files
      then Ok () else Error "site entry is not valid UTF-8" in
  Ok { receipt }
let input_to_json (input : input) =
  receipt_to_json ~schema:"masc.artifact_project_result.v1" ~install:worker_install_json ~output:worker_output_json input.receipt
let input_of_receipt receipt = input_of_json (input_to_json { receipt })
let reference ~mime json = match Tool_output.normalized_artifact_ref_of_json json with
  | Tool_output.Decoded_normalized_artifact_ref body when String.equal body.mime mime && String.is_valid_utf_8 body.preview -> Ok body
  | Tool_output.Decoded_normalized_artifact_ref _ | Tool_output.Not_normalized_artifact_ref
  | Tool_output.Invalid_normalized_artifact_ref _ -> Error "invalid build payload reference"
let stored_output = output_of_json ~identity:ref_identity
  ~html:(fun json -> let* fields = object_fields ["format"; "body"] json in
    let* () = exact "format" "html" fields in reference ~mime:"text/html" (value "body" fields))
  ~file:(fun json -> let* fields = object_fields ["path"; "body"] json in
    let* path = path "path" fields in let* body = reference ~mime:"application/octet-stream" (value "body" fields) in Ok { path; body })
let stored_output_json = output_to_json
  ~html:(fun body -> `Assoc ["format", `String "html"; "body", Tool_output.normalized_artifact_ref_to_json body])
  ~file:(fun file -> `Assoc ["path", `String file.path; "body", Tool_output.normalized_artifact_ref_to_json file.body])
let stored_install = install_of_json ~keys:["lock"] ~lock:(fun fields -> reference ~mime:"application/json" (value "lock" fields))
let stored_install_json = install_to_json ~lock:(fun body -> ["lock", Tool_output.normalized_artifact_ref_to_json body])
let to_json (build : t) = `Assoc ["schema", `String "masc.artifact_project_build.v1";
  "id", `String build.id; "source_id", `String build.source_id; "author", `String build.author;
  "created_at", `String build.created_at;
  "receipt", receipt_to_json ~schema:"masc.artifact_project_result_refs.v1" ~install:stored_install_json ~output:stored_output_json build.receipt]
let of_json json =
  let* fields = object_fields ["schema"; "id"; "source_id"; "author"; "created_at"; "receipt"] json in
  let* () = exact "schema" "masc.artifact_project_build.v1" fields in
  let* id = nonblank "id" fields in let* source_id = nonblank "source_id" fields in
  let* () = if valid_id id && Artifact_project_source.valid_id source_id then Ok () else Error "invalid build or source id" in
  let* author = nonblank "author" fields in let* created_at = nonblank "created_at" fields in
  let* receipt = receipt_of_json ~schema:"masc.artifact_project_result_refs.v1" ~install:stored_install ~output:stored_output (value "receipt" fields) in
  Ok { id; source_id; author; created_at; receipt }

let map_bodies f (receipt : 'a receipt) =
  let* lock = f ~mime:"application/json" receipt.install.lock in
  let* output = match receipt.output with
    | Html body -> let* body = f ~mime:"text/html" body in Ok (Html body)
    | Site site ->
      let* files = List.fold_left (fun acc file -> let* acc = acc in
        let* body = f ~mime:"application/octet-stream" file.body in Ok ({ path = file.path; body } :: acc)) (Ok []) site.files in
      Ok (Site { site with files = List.rev files }) in
  Ok { receipt with install = { receipt.install with lock }; output }
let validate_source ~digest ~source (receipt : 'a receipt) =
  let expected = List.map (fun (file : Artifact_project_source.stored_file) ->
    ({ path = file.path; sha256 = file.body.sha256 } : source_file)) source.Artifact_project_source.files in
  let* () = if receipt.source_files = expected then Ok () else Error "build source files differ from source snapshot" in
  let* () = match source.build, receipt.build with
    | Artifact_project_source.Browser_modules a, Browser_modules b when String.equal a.entry_html b.entry_html -> Ok ()
    | Artifact_project_source.Package_script a, Package_script b
      when a.script = b.script && a.output_directory = b.output_directory && a.entry_html = b.entry_html -> Ok ()
    | Artifact_project_source.Browser_modules _, Browser_modules _
    | Artifact_project_source.Browser_modules _, Package_script _
    | Artifact_project_source.Package_script _, Browser_modules _
    | Artifact_project_source.Package_script _, Package_script _ -> Error "build selection differs from source snapshot" in
  let* () = if source.install_scripts = receipt.install.scripts then Ok () else Error "install hooks differ from source snapshot" in
  let find lockfile = List.find_opt (fun (file : Artifact_project_source.stored_file) -> String.equal file.path (lockfile_name lockfile)) source.files in
  let supplied = match find Shrinkwrap with Some file -> Some (Shrinkwrap, file) | None ->
    Option.map (fun file -> Package_lock, file) (find Package_lock) in
  match supplied, receipt.install.lock_source, receipt.install.lockfile with
  | None, Resolved, Package_lock -> Ok ()
  | Some (lockfile, file), Supplied, actual
    when lockfile = actual && String.equal file.body.sha256 (digest receipt.install.lock) -> Ok ()
  | None, Supplied, _ | None, Resolved, Shrinkwrap | Some _, Resolved, _ | Some _, Supplied, _ ->
    Error "installation lock differs from source snapshot"
