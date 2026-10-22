let ( let* ) = Result.bind

type declaration =
  | Created of { path : string }
  | Present of { path : string; manifest_path : string; this_build : bool; enabled : bool }

type installed =
  { package_directory : string
  ; files_written : int
  ; files_removed : int
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
  | Declared_more_than_once of string list
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
  | Declared_more_than_once paths ->
    Printf.sprintf
      "The browser Add-on is declared more than once (%s). The server would attach every \
       one and refuse browser hosts as ambiguous. Keep one and set enabled = false in, or \
       remove, the others."
      (String.concat ", " paths)
  | Declaration_unloadable { path; reason } ->
    Printf.sprintf
      "The browser Add-on declaration %s does not load: %s. It is left as it is; fix or \
       remove it, then run masc browser-lane-setup --mode addon again."
      path reason
  | Declaration_refused reason -> "The browser Add-on declaration was refused: " ^ reason

(* The folder under packages/ and the declaration's id and file name. The
   manifest's own id must be the same; [apply] checks it after loading. *)
let package_name = "browser"
let packages_dirname = "packages"
let manifest_name = "lane.toml"
let declaration_file_name = package_name ^ ".toml"

let package_directory ~base_path =
  List.fold_left Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    [ packages_dirname; package_name ]

let embedded_files () =
  match Embedded_browser_addon.read manifest_name with
  | None -> Error (Embedded_package_invalid ("it carries no " ^ manifest_name))
  | Some _ ->
    List.fold_right
      (fun name collected ->
         let* collected = collected in
         match Embedded_browser_addon.read name with
         | Some contents -> Ok ((name, contents) :: collected)
         | None ->
           Error
             (Embedded_package_invalid
                (Printf.sprintf "it lists %s and carries no bytes for it" name)))
      Embedded_browser_addon.file_list
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
              | () -> Ok (removed + inside)
              | exception Unix.Unix_error ((Unix.ENOTEMPTY | Unix.EEXIST), _, _) ->
                Ok (removed + inside)
              | exception Unix.Unix_error (error, _, _) -> unwritable path (Unix.error_message error))
           | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
             if List.mem relative carried
             then Ok removed
             else (
               match Sys.remove path with
               | () -> Ok (removed + 1)
               | exception Sys_error reason -> unwritable path reason))
        (Ok 0) entries
  in
  walk ""

(* Each file is replaced atomically and the manifest goes last, so a reader
   that sees the new manifest also sees the schemas and the skill it names. *)
let write_package ~directory files =
  let manifest, others = List.partition (fun (name, _) -> String.equal name manifest_name) files in
  let* written = write_files ~directory others in
  let* removed = remove_leftovers ~directory files in
  let* manifest_written = write_files ~directory manifest in
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

let declaration_text ~manifest_path ~package_directory =
  String.concat "\n"
    [ "# Declared by masc browser-lane-setup. manifest_path names the browser Add-on"
    ; "# package that masc writes to " ^ package_directory ^ "; setup and"
    ; "# install-local-build.sh rewrite that package when masc is upgraded, so this"
    ; "# file does not change. Set enabled = false to keep the Add-on detached."
    ; Toml_line_editor.scalar_line ~key:"id" ~value:package_name
    ; "enabled = true"
    ; Toml_line_editor.scalar_line ~key:"run_id" ~value:package_name
    ; Toml_line_editor.scalar_line ~key:"manifest_path" ~value:manifest_path
    ; ""
    ; "[binding]"
    ; "sources = []"
    ; ""
    ]

let declare ~directory ~manifest_path ~package_directory =
  let request =
    `Assoc
      [ "mode", `String "create"
      ; "file_name", `String declaration_file_name
      ; "source_text", `String (declaration_text ~manifest_path ~package_directory)
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

(* The one declaration of the browser package, if there is one. *)
let browser_declaration (snapshot : Lane_addon_config.snapshot) =
  match
    List.filter
      (fun (declared : Lane_addon_config.declaration) ->
         String.equal declared.package.id package_name)
      snapshot.declarations
  with
  | [] -> Ok None
  | [ declared ] -> Ok (Some declared)
  | _ :: _ :: _ as declared ->
    Error
      (Declared_more_than_once
         (List.map (fun (d : Lane_addon_config.declaration) -> d.source_path) declared))

type plan =
  { base_path : string
  ; lane_directory : string
  ; files : (string * string) list
  }

let plan ~base_path =
  if Filename.is_relative base_path
  then Error (Base_path_not_absolute base_path)
  else
    let* lane_directory = lane_directory ~base_path in
    let* snapshot = read_inventory ~lane_directory in
    let* (_ : Lane_addon_config.declaration option) = browser_declaration snapshot in
    let* files = embedded_files () in
    Ok { base_path; lane_directory; files }

let apply plan =
  let directory = package_directory ~base_path:plan.base_path in
  let* files_written, files_removed = write_package ~directory plan.files in
  let manifest_path = Filename.concat directory manifest_name in
  let* (package : Lane_addon_types.package) =
    Lane_addon_manifest.load ~path:manifest_path
    |> Result.map_error (fun error ->
      Package_unloadable
        { path = manifest_path; reason = Lane_addon_manifest.error_to_string error })
  in
  let* () =
    if String.equal package.id package_name
    then Ok ()
    else
      Error
        (Embedded_package_invalid
           (Printf.sprintf "its manifest id is %S, not %S" package.id package_name))
  in
  (* Read again now that the package is in place. A declaration that did not
     load because its package was missing loads now, and one written since
     [plan] is seen. *)
  let* snapshot = read_inventory ~lane_directory:plan.lane_directory in
  let* existing = browser_declaration snapshot in
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
      let own = Filename.concat plan.lane_directory declaration_file_name in
      (match
         List.find_opt
           (fun (issue : Lane_addon_config.issue) ->
              String.equal issue.source_path own || issue.id = Some package_name)
           snapshot.issues
       with
       | Some issue ->
         Error (Declaration_unloadable { path = issue.source_path; reason = issue.message })
       | None -> declare ~directory:plan.lane_directory ~manifest_path ~package_directory:directory)
  in
  Ok
    { package_directory = directory
    ; files_written
    ; files_removed
    ; declaration
    ; missing_programs = missing_programs ~package_directory:directory package
    }
