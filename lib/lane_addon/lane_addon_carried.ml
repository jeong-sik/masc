open Result.Syntax

type id = Keeper_librarian | Workspace_curator | Candle_appraiser | Hitl_auto_judge

let all = [Keeper_librarian; Workspace_curator; Candle_appraiser; Hitl_auto_judge]

let name = function
  | Keeper_librarian -> "keeper-librarian"
  | Workspace_curator -> "workspace-curator"
  | Candle_appraiser -> "candle-appraiser"
  | Hitl_auto_judge -> "hitl-auto-judge"

let of_name value = List.find_opt (fun id -> String.equal (name id) value) all

type file = { path : string; contents : string }

let by_path a b = String.compare a.path b.path

(* ocaml-crunch lists every file it wrote, so [read] answers each listed path. *)
let files_of file_list read =
  List.filter_map (fun path -> Option.map (fun contents -> { path; contents }) (read path)) file_list
  |> List.sort by_path

let package_files = function
  | Keeper_librarian -> files_of Embedded_keeper_librarian.file_list Embedded_keeper_librarian.read
  | Workspace_curator -> files_of Embedded_workspace_curator.file_list Embedded_workspace_curator.read
  | Candle_appraiser -> files_of Embedded_candle_appraiser.file_list Embedded_candle_appraiser.read
  | Hitl_auto_judge -> files_of Embedded_hitl_auto_judge.file_list Embedded_hitl_auto_judge.read

let shared_files = files_of Embedded_exact_worker_shared.file_list Embedded_exact_worker_shared.read

let manifest_name = "lane.toml"

let one_segment value =
  value <> "" && value <> Filename.current_dir_name && value <> Filename.parent_dir_name
  && not (String.contains value '/') && not (String.contains value '\000')

let revision id =
  match List.find_opt (fun file -> String.equal file.path manifest_name) (package_files id) with
  | None -> Error (name id ^ " carries no " ^ manifest_name)
  | Some manifest ->
    match Otoml.Parser.from_string_result manifest.contents with
    | Error message -> Error message
    | Ok (Otoml.TomlTable fields) ->
      (match List.assoc_opt "revision" fields with
       | Some (Otoml.TomlString revision) when one_segment revision -> Ok revision
       | Some (Otoml.TomlString revision) -> Error (Printf.sprintf "revision %S is not one path segment" revision)
       | None | Some ( Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
                     | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
                     | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
                     | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) ->
         Error "revision requires a string")
    | Ok ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
         | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
         | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlInlineTable _
         | Otoml.TomlTableArray _ ) -> Error (manifest_name ^ " requires a TOML table")

let folder ~packages id =
  let+ revision = revision id in
  Filename.concat packages (name id ^ "-" ^ revision)

type installation_error =
  | Not_installed of { folder : string }
  | Differs of { folder : string; detail : string }
  | Carried_package_invalid of string

type placed = Absent | Unusable of string | Files of file list

let io_detail = function
  | Unix.Unix_error (error, call, arg) -> call ^ " " ^ arg ^ ": " ^ Unix.error_message error
  | Sys_error message -> message
  | exn -> raise exn

(* Every regular file under [folder], relative to it, in path order. *)
let read_placed folder =
  let rec walk relative files =
    let path = if relative = "" then folder else Filename.concat folder relative in
    let* stat = try Ok (Unix.lstat path) with Unix.Unix_error _ as exn -> Error (io_detail exn) in
    match stat.Unix.st_kind with
    | Unix.S_REG ->
      let+ contents =
        try Ok (In_channel.with_open_bin path In_channel.input_all)
        with (Sys_error _ | Unix.Unix_error _) as exn -> Error (io_detail exn) in
      { path = relative; contents } :: files
    | Unix.S_DIR ->
      let* entries = try Ok (Sys.readdir path) with Sys_error _ as exn -> Error (io_detail exn) in
      Array.sort String.compare entries;
      Array.fold_left (fun files entry ->
          let* files = files in
          walk (if relative = "" then entry else Filename.concat relative entry) files)
        (Ok files) entries
    | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
      Error ((if relative = "" then folder else relative) ^ " is not a regular file or directory")
  in
  match (Unix.lstat folder).Unix.st_kind with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Absent
  | exception (Unix.Unix_error _ as exn) -> Unusable (io_detail exn)
  | Unix.S_DIR ->
    (match walk "" [] with
     | Ok files -> Files (List.sort by_path files)
     | Error detail -> Unusable detail)
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
    Unusable (folder ^ " is not a directory")

let rec first_difference carried placed =
  match carried, placed with
  | [], [] -> None
  | file :: _, [] -> Some ("missing " ^ file.path)
  | [], file :: _ -> Some ("unexpected " ^ file.path)
  | carried_file :: carried_rest, placed_file :: placed_rest ->
    let order = String.compare carried_file.path placed_file.path in
    if order < 0 then Some ("missing " ^ carried_file.path)
    else if order > 0 then Some ("unexpected " ^ placed_file.path)
    else if not (String.equal carried_file.contents placed_file.contents)
    then Some (carried_file.path ^ " has other bytes")
    else first_difference carried_rest placed_rest

let installed_manifest ~packages id =
  match folder ~packages id with
  | Error detail -> Error (Carried_package_invalid detail)
  | Ok folder ->
    match read_placed folder with
    | Absent -> Error (Not_installed { folder })
    | Unusable detail -> Error (Differs { folder; detail })
    | Files placed ->
      match first_difference (package_files id) placed with
      | None -> Ok (Filename.concat folder manifest_name)
      | Some detail -> Error (Differs { folder; detail })

let installation_error_to_string id = function
  | Not_installed { folder } ->
    Printf.sprintf "the %s package this server carries is not installed: %s does not exist" (name id) folder
  | Differs { folder; detail } ->
    Printf.sprintf "%s is not the %s package this server carries: %s" folder (name id) detail
  | Carried_package_invalid detail ->
    Printf.sprintf "the %s package this server carries has no usable revision: %s" (name id) detail
