(* The masc pad (RFC play-link-for-the-shared-machine §2.9). *)

type button =
  | South
  | East
  | North
  | West
  | Dpad_up
  | Dpad_down
  | Dpad_left
  | Dpad_right
  | Start
  | Select
  | Tl
  | Tr

let all_buttons =
  [ South; East; North; West; Dpad_up; Dpad_down; Dpad_left; Dpad_right; Start; Select; Tl; Tr ]

let button_to_string = function
  | South -> "BTN_SOUTH"
  | East -> "BTN_EAST"
  | North -> "BTN_NORTH"
  | West -> "BTN_WEST"
  | Dpad_up -> "BTN_DPAD_UP"
  | Dpad_down -> "BTN_DPAD_DOWN"
  | Dpad_left -> "BTN_DPAD_LEFT"
  | Dpad_right -> "BTN_DPAD_RIGHT"
  | Start -> "BTN_START"
  | Select -> "BTN_SELECT"
  | Tl -> "BTN_TL"
  | Tr -> "BTN_TR"

let button_of_string name =
  match List.find_opt (fun b -> String.equal (button_to_string b) name) all_buttons with
  | Some button -> Ok button
  | None ->
    Error
      (Printf.sprintf "%S is not a pad button: one of %s" name
         (String.concat ", " (List.map button_to_string all_buttons)))

type binding =
  { keys : string list
  ; label : string
  }

type layout = (button * binding) list

let bindings layout =
  List.filter_map (fun b -> Option.map (fun binding -> b, binding) (List.assoc_opt b layout)) all_buttons

let binding layout button = List.assoc_opt button layout

let kind_name = function
  | Otoml.TomlString _ -> "a string"
  | Otoml.TomlInteger _ -> "an integer"
  | Otoml.TomlFloat _ -> "a float"
  | Otoml.TomlBoolean _ -> "a boolean"
  | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
  | Otoml.TomlLocalTime _ -> "a date or time"
  | Otoml.TomlArray _ -> "an array"
  | Otoml.TomlTable _ | Otoml.TomlInlineTable _ -> "a table"
  | Otoml.TomlTableArray _ -> "an array of tables"

let binding_fields = [ "keys"; "label" ]

let parse_key ~button value =
  match value with
  | Otoml.TomlString name ->
    Result.map_error
      (fun message -> Printf.sprintf "%s: key %S: %s" button name message)
      (Result.map (fun () -> name) (Dos_lane.check_key_name name))
  | other -> Error (Printf.sprintf "%s: keys holds %s, not a key name" button (kind_name other))

let parse_binding ~button fields =
  let ( let* ) = Result.bind in
  let* () =
    match List.find_opt (fun (field, _) -> not (List.mem field binding_fields)) fields with
    | Some (field, _) -> Error (Printf.sprintf "%s: unknown field %S (keys, label)" button field)
    | None -> Ok ()
  in
  let* keys =
    match List.assoc_opt "keys" fields with
    | None -> Error (Printf.sprintf "%s: keys is required" button)
    | Some (Otoml.TomlArray []) -> Error (Printf.sprintf "%s: keys is empty; leave the button out instead" button)
    | Some (Otoml.TomlArray items) ->
      List.fold_right
        (fun item acc ->
          let* rest = acc in
          let* key = parse_key ~button item in
          Ok (key :: rest))
        items (Ok [])
    | Some other -> Error (Printf.sprintf "%s: keys must be an array, got %s" button (kind_name other))
  in
  let* label =
    match List.assoc_opt "label" fields with
    | Some (Otoml.TomlString label) when String.trim label <> "" -> Ok label
    | Some (Otoml.TomlString _) -> Error (Printf.sprintf "%s: label is empty" button)
    | None -> Error (Printf.sprintf "%s: label is required" button)
    | Some other -> Error (Printf.sprintf "%s: label must be a string, got %s" button (kind_name other))
  in
  Ok { keys; label }

let parse contents =
  let ( let* ) = Result.bind in
  match Otoml.Parser.from_string_result contents with
  | Error message -> Error ("not TOML: " ^ message)
  | Ok (Otoml.TomlTable tables | Otoml.TomlInlineTable tables) ->
    List.fold_left
      (fun acc (name, value) ->
        let* layout = acc in
        let* button = button_of_string name in
        let* () =
          if List.mem_assoc button layout then Error (Printf.sprintf "%s is bound twice" name) else Ok ()
        in
        match value with
        | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
          let* binding = parse_binding ~button:name fields in
          Ok ((button, binding) :: layout)
        | other -> Error (Printf.sprintf "%s must be a table, got %s" name (kind_name other)))
      (Ok []) tables
  | Ok other -> Error (Printf.sprintf "a layout is a table of buttons, got %s" (kind_name other))

type source =
  | Workspace
  | Builtin

let source_to_string = function
  | Workspace -> "workspace"
  | Builtin -> "builtin"

let pads_dir ~base_path =
  Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "dos") "pads"

(* Builtin layouts are data assets, not cases in the pad implementation. A
   game package can ship [config/pads/<inventory-name>.toml] and the generic
   loader discovers it from the same embedded config tree as the other
   distribution assets. Keeping the inventory name in the asset filename is
   the only coupling needed to select a layout. *)
let builtin_pads_prefix = "pads/"
let toml_suffix = ".toml"

let builtin_layout_name path =
  let prefix_length = String.length builtin_pads_prefix in
  let suffix_length = String.length toml_suffix in
  let path_length = String.length path in
  if
    not (String.starts_with ~prefix:builtin_pads_prefix path)
    || not (String.ends_with ~suffix:toml_suffix path)
    || path_length <= prefix_length + suffix_length
  then None
  else
    let name_length = path_length - prefix_length - suffix_length in
    let name = String.sub path prefix_length name_length in
    (* Only one inventory component is valid here. A nested asset should not
       silently become a different program's layout. *)
    if name = "" || String.contains name '/' || String.contains name '\\' then None else Some name

let builtin_layouts () =
  Embedded_config.file_list
  |> List.filter_map (fun path ->
    match builtin_layout_name path with
    | None -> None
    | Some name -> Option.map (fun contents -> name, contents) (Embedded_config.read path))

(* The saves name is the inventory entry, including a standalone program's
   extension. Use the loader's boundary: one plain name, not a path or drive. *)
let is_file_component name =
  name <> "" && not (Dos_lane.escapes name)

let workspace_file_error path detail =
  Printf.sprintf "workspace pad layout %s: %s" path detail

let read_regular_workspace_file path =
  (* The path was regular when examined. NONBLOCK also avoids waiting for a
     writer if it is replaced by a FIFO before open; fstat checks what was
     actually opened, before any contents are read. *)
  try
    let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC] 0 in
    let channel = Unix.in_channel_of_descr fd in
    Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      match (Unix.fstat fd).Unix.st_kind with
      | Unix.S_REG -> Ok (In_channel.input_all channel)
      | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
        Error (workspace_file_error path "not a regular file"))
  with
  | Unix.Unix_error (error, _, _) -> Error (workspace_file_error path (Unix.error_message error))
  | Sys_error detail -> Error (workspace_file_error path detail)

let workspace_contents path =
  (* Failed stat is not absence. A dangling leaf link also gives ENOENT to
     stat, but lstat still sees the explicitly supplied workspace override. *)
  match Unix.stat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    (match Unix.lstat path with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
     | exception Unix.Unix_error (error, _, _) ->
       Error (workspace_file_error path (Unix.error_message error))
     | (_ : Unix.stats) -> Error (workspace_file_error path "link target does not exist"))
  | exception Unix.Unix_error (error, _, _) ->
    Error (workspace_file_error path (Unix.error_message error))
  | {Unix.st_kind=Unix.S_REG;_} -> Result.map Option.some (read_regular_workspace_file path)
  | {Unix.st_kind=Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK;_} ->
    Error (workspace_file_error path "not a regular file")

let load ~base_path ~saves_name =
  if not (is_file_component saves_name) then
    Error (Printf.sprintf "%S is not an inventory name" saves_name)
  else
    let path = Filename.concat (pads_dir ~base_path) (saves_name ^ ".toml") in
    let parsed source contents =
      Result.map (fun layout -> Some (source, layout))
        (Result.map_error (fun message -> Printf.sprintf "%s layout for %s: %s"
                              (source_to_string source) saves_name message)
           (parse contents))
    in
    match workspace_contents path with
    | Error message -> Error message
    | Ok (Some contents) -> parsed Workspace contents
    | Ok None ->
      match List.assoc_opt saves_name (builtin_layouts ()) with
      | Some contents -> parsed Builtin contents
      | None -> Ok None
