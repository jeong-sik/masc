open Result.Syntax

type declaration =
  | Created of { path : string }
  | Present of { path : string; manifest_path : string; this_build : bool; enabled : bool }

type installed =
  { backend : Browser_lane.Backend.t
  ; package_directory : string
  ; manifest_path : string
  ; files_written : int
  ; files_removed : string list
  ; declaration : declaration
  ; missing_programs : string list
  }

type error =
  | Base_path_not_absolute of string
  | Embedded_package_invalid of string
  | Package_unwritable of { path : string; reason : string }
  | Package_unloadable of { path : string; reason : string }
  | Config_root_invalid of string
  | Config_root_missing of string
  | Inventory_unreadable of { directory : string }
  | Declared_more_than_once of { backend : Browser_lane.Backend.t; paths : string list }
  | Declaration_unloadable of { path : string; reason : string }
  | Declaration_refused of string

let error_message = function
  | Base_path_not_absolute path -> Printf.sprintf "--base-path must be absolute, got %s" path
  | Embedded_package_invalid reason ->
    "The browser Add-on package this masc carries is unusable: " ^ reason
  | Package_unwritable { path; reason } ->
    Printf.sprintf "Could not write the browser Add-on package file %s: %s" path reason
  | Package_unloadable { path; reason } ->
    Printf.sprintf "The browser Add-on package at %s does not load with this masc: %s" path reason
  | Config_root_invalid reason -> "The workspace config root is invalid: " ^ reason
  | Config_root_missing path ->
    Printf.sprintf
      "The workspace has no config root at %s yet, so the browser Add-on was not declared. \
       Create the workspace first, then run masc browser-lane-setup --mode addon."
      path
  | Inventory_unreadable { directory } ->
    Printf.sprintf
      "Could not read every Lane declaration in %s, so whether the browser Add-on is \
       already declared is unknown. Nothing was declared."
      directory
  | Declared_more_than_once { backend; paths } ->
    Printf.sprintf
      "The %s browser source is declared and enabled more than once (%s). The server uses \
       neither while both are attached. Keep one enabled and set enabled = false in, or \
       remove, the others."
      (Browser_lane.Backend.to_wire backend) (String.concat ", " paths)
  | Declaration_unloadable { path; reason } ->
    Printf.sprintf
      "The browser Add-on declaration %s does not load: %s. It is left as it is; fix or \
       remove it, then run masc browser-lane-setup --mode addon again."
      path reason
  | Declaration_refused reason -> "The browser Add-on declaration was refused: " ^ reason

(* Each browser source's package: its folder in the carried tree, and the
   folder under packages/, the declaration's id and its file name. The
   manifest's own id and source must be the same; [apply] checks them. *)
let package_folder = function
  | Browser_lane.Backend.Automation -> "automation"
  | Stagehand -> "stagehand"
  | Owned_firefox -> "firefox"
  | Ego -> "ego"
  | External_host -> "external"
let package_name backend = "browser-" ^ package_folder backend
let packages_dirname = "packages"
let manifest_name = "lane.toml"
let declaration_file_name backend = package_name backend ^ ".toml"

let package_directory ~base_path backend =
  List.fold_left Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    [ packages_dirname; package_name backend ]

let embedded_files backend =
  let prefix = package_folder backend ^ "/" in
  let carried =
    List.filter_map
      (fun name -> if String.starts_with ~prefix name
        then Some (name, String.sub name (String.length prefix) (String.length name - String.length prefix))
        else None)
      Embedded_browser_addon.file_list
  in
  if not (List.exists (fun (_, name) -> String.equal name manifest_name) carried)
  then Error (Embedded_package_invalid (Printf.sprintf "it carries no %s%s" prefix manifest_name))
  else
    List.fold_right
      (fun (carried_name, name) collected ->
         let* collected = collected in
         match Embedded_browser_addon.read carried_name with
         | Some contents -> Ok ((name, contents) :: collected)
         | None ->
           Error
             (Embedded_package_invalid
                (Printf.sprintf "it lists %s and carries no bytes for it" carried_name)))
      carried
      (Ok [])

let current_bytes path =
  match In_channel.with_open_bin path In_channel.input_all with
  | contents -> Some contents
  | exception Sys_error _ -> None

let write_files ~directory files =
  List.fold_left
    (fun written (name, contents) ->
       let* written = written in
       let path = Filename.concat directory name in
       if current_bytes path = Some contents
       then Ok written
       else
         match Fs_compat.mkdir_p (Filename.dirname path) with
         | exception (Unix.Unix_error _ | Sys_error _ as exn) ->
           Error (Package_unwritable { path; reason = Printexc.to_string exn })
         | () ->
           (match Fs_compat.save_file_atomic_strict_staged path contents with
            | Ok () -> Ok (written + 1)
            | Error failure ->
              Error
                (Package_unwritable
                   { path; reason = Fs_compat.atomic_replace_failure_to_string failure })))
    (Ok 0) files

(* The package directory belongs to setup, so a file this build does not carry
   is one an earlier build wrote. It is removed: the server would still read
   it, and it publishes the skills directory as a whole tree. A directory left
   empty goes too; the package directory itself stays. *)
let remove_leftovers ~directory files =
  let carried = List.map fst files in
  let unwritable path reason = Error (Package_unwritable { path; reason }) in
  let rec walk relative =
    let here = if String.equal relative "" then directory else Filename.concat directory relative in
    match Sys.readdir here with
    | exception Sys_error reason -> unwritable here reason
    | entries ->
      Array.sort String.compare entries;
      Array.fold_left
        (fun removed entry ->
           let* removed = removed in
           let relative = if String.equal relative "" then entry else Filename.concat relative entry in
           let path = Filename.concat directory relative in
           match (Unix.lstat path).Unix.st_kind with
           | exception Unix.Unix_error (error, _, _) -> unwritable path (Unix.error_message error)
           | Unix.S_DIR ->
             let* inside = walk relative in
             (match Unix.rmdir path with
              | () -> Ok (removed @ inside)
              | exception Unix.Unix_error ((Unix.ENOTEMPTY | Unix.EEXIST), _, _) ->
                Ok (removed @ inside)
              | exception Unix.Unix_error (error, _, _) -> unwritable path (Unix.error_message error))
           | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
             if List.mem relative carried
             then Ok removed
             else (
               match Sys.remove path with
               | () -> Ok (removed @ [ path ])
               | exception Sys_error reason -> unwritable path reason))
        (Ok []) entries
  in
  walk ""

(* Each file is replaced atomically and the manifest comes after the files it
   names, so a reader that sees the new manifest also sees its schemas and
   skill. Leftovers go last: until the new manifest is in place, the old one
   still finds every file it names. *)
let write_package ~directory files =
  let manifest, others = List.partition (fun (name, _) -> String.equal name manifest_name) files in
  let* written = write_files ~directory others in
  let* manifest_written = write_files ~directory manifest in
  let* removed = remove_leftovers ~directory files in
  Ok (written + manifest_written, removed)

let missing_programs ~package_directory (package : Lane_addon_types.package) =
  let worker =
    match package.command with
    | [] -> []
    | command :: _ ->
      if Native_addon_program.command_ready ~package_directory command then [] else [ command ]
  in
  worker
  @ List.filter_map
      (fun program ->
         match Native_addon_program.locate program with
         | Ok _ -> None
         | Error _ -> Some (Native_addon_program.name program))
      Native_addon_program.all

let same_file a b =
  match Unix.realpath a, Unix.realpath b with
  | a, b -> String.equal a b
  | exception (Unix.Unix_error _ | Sys_error _) -> false

let declaration_text ~backend ~manifest_path ~package_directory =
  String.concat "\n"
    [ "# Declared by masc browser-lane-setup. manifest_path names the browser Add-on"
    ; "# package of the " ^ Browser_lane.Backend.to_wire backend ^ " source that masc writes to"
    ; "# " ^ package_directory ^ "; setup and install-local-build.sh rewrite that"
    ; "# package when masc is upgraded, so this file does not change. Set"
    ; "# enabled = false to keep the Add-on detached."
    ; Toml_line_editor.scalar_line ~key:"id" ~value:(package_name backend)
    ; "enabled = true"
    ; Toml_line_editor.scalar_line ~key:"run_id" ~value:(package_name backend)
    ; Toml_line_editor.scalar_line ~key:"manifest_path" ~value:manifest_path
    ; ""
    ; "[binding]"
    ; "sources = []"
    ; ""
    ]

let declare ~backend ~directory ~manifest_path ~package_directory =
  let request =
    `Assoc
      [ "mode", `String "create"
      ; "file_name", `String (declaration_file_name backend)
      ; "source_text", `String (declaration_text ~backend ~manifest_path ~package_directory)
      ]
  in
  let refused (error : Lane_addon_declaration.error) = Declaration_refused error.message in
  let* request = Lane_addon_declaration.write_request request |> Result.map_error refused in
  let* (receipt : Lane_addon_declaration.receipt) =
    Lane_addon_declaration.write ~directory request |> Result.map_error refused
  in
  Ok (Created { path = receipt.document.source_path })

let lane_directory ~base_path =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path in
  match resolution.Config_dir_resolver.status with
  | Config_dir_resolver.Invalid_env_status ->
    Error (Config_root_invalid (String.concat "; " resolution.warnings))
  | Missing_status -> Error (Config_root_missing resolution.config_root.path)
  | Ready | Warn -> Ok (Lane_addon_config.directory ~config_root:resolution.config_root.path)

let read_inventory ~lane_directory =
  let snapshot = Lane_addon_config.load ~directory:lane_directory in
  if snapshot.Lane_addon_config.complete
  then Ok snapshot
  else Error (Inventory_unreadable { directory = lane_directory })

(* The declaration of a source's package that counts, if there is one. The
   server attaches only enabled declarations, so only those can double the
   source. With none enabled, the first disabled one stands for the
   operator's choice to keep the Add-on detached, and nothing is declared. *)
let browser_declaration backend (snapshot : Lane_addon_config.snapshot) =
  let declared =
    List.filter
      (fun declared -> Lane_addon_config.browser_source declared = Some backend)
      snapshot.declarations
  in
  match List.filter (fun (d : Lane_addon_config.declaration) -> d.enabled) declared with
  | [ enabled ] -> Ok (Some enabled)
  | _ :: _ :: _ as enabled ->
    Error
      (Declared_more_than_once
         { backend; paths = List.map (fun (d : Lane_addon_config.declaration) -> d.source_path) enabled })
  | [] ->
    (match declared with
     | [] -> Ok None
     | disabled :: _ -> Ok (Some disabled))

type plan =
  { base_path : string
  ; lane_directory : string
  ; packages : (Browser_lane.Backend.t * (string * string) list) list
  }

let plan ~base_path ~sources =
  if Filename.is_relative base_path
  then Error (Base_path_not_absolute base_path)
  else
    let* lane_directory = lane_directory ~base_path in
    let* snapshot = read_inventory ~lane_directory in
    let* packages =
      List.fold_right
        (fun backend collected ->
           let* collected = collected in
           let* (_ : Lane_addon_config.declaration option) = browser_declaration backend snapshot in
           let* files = embedded_files backend in
           Ok ((backend, files) :: collected))
        (List.sort_uniq compare sources)
        (Ok [])
    in
    Ok { base_path; lane_directory; packages }

let apply_package plan (backend, files) =
  let directory = package_directory ~base_path:plan.base_path backend in
  let* files_written, files_removed = write_package ~directory files in
  let manifest_path = Filename.concat directory manifest_name in
  let* (package : Lane_addon_types.package) =
    Lane_addon_manifest.load ~path:manifest_path
    |> Result.map_error (fun error ->
      Package_unloadable
        { path = manifest_path; reason = Lane_addon_manifest.error_to_string error })
  in
  let* () =
    match String.equal package.id (package_name backend), package.worker_service with
    | true, Lane_addon_types.Browser_service served when served = backend -> Ok ()
    | (true | false), (Lane_addon_types.Browser_service _ | Lane_addon_types.Mcp_tools) ->
      Error
        (Embedded_package_invalid
           (Printf.sprintf "the manifest at %s is not the %s package of the %s source"
              manifest_path (package_name backend) (Browser_lane.Backend.to_wire backend)))
  in
  (* Read again now that the package is in place. A declaration that did not
     load because its package was missing loads now, and one written since
     [plan] is seen. *)
  let* snapshot = read_inventory ~lane_directory:plan.lane_directory in
  let* existing = browser_declaration backend snapshot in
  let* declaration =
    match existing with
    | Some (declared : Lane_addon_config.declaration) ->
      Ok
        (Present
           { path = declared.source_path
           ; manifest_path = declared.manifest_path
           ; this_build = same_file declared.manifest_path manifest_path
           ; enabled = declared.enabled
           })
    | None ->
      let own = Filename.concat plan.lane_directory (declaration_file_name backend) in
      (match
         List.find_opt
           (fun (issue : Lane_addon_config.issue) ->
              String.equal issue.source_path own || issue.id = Some (package_name backend))
           snapshot.issues
       with
       | Some issue ->
         Error (Declaration_unloadable { path = issue.source_path; reason = issue.message })
       | None -> declare ~backend ~directory:plan.lane_directory ~manifest_path ~package_directory:directory)
  in
  Ok
    { backend
    ; package_directory = directory
    ; manifest_path
    ; files_written
    ; files_removed
    ; declaration
    ; missing_programs = missing_programs ~package_directory:directory package
    }

type applied = { installed : installed list; refusal : error option }

(* Packages are written one after another; a refusal leaves the ones before
   it written and declared, and they are returned with it. *)
let apply plan =
  let rec go installed = function
    | [] -> { installed = List.rev installed; refusal = None }
    | package :: rest ->
      (match apply_package plan package with
       | Ok one -> go (one :: installed) rest
       | Error error -> { installed = List.rev installed; refusal = Some error }) in
  go [] plan.packages

let without sources plan =
  { plan with packages = List.filter (fun (backend, _) -> not (List.mem backend sources)) plan.packages }
