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

(* 삼국지 III, from the prompts the sangokushi-3 Skill observed: numbered
   prompts answered with a number and enter, Y/N questions, and "press any
   key". Numbers and names go through the page's text box, not the pad.

   The battle map is made of hexes, and its cursor moves on the digit keys:
   8 up, 2 down, 7 up-left, 9 up-right, 1 down-left, 3 down-right. The arrow
   keys, 4 and 6 do nothing there, so the pad sends digits: the D-pad for the
   four upper and vertical hexes, the shoulders for the two lower diagonals.
   Placing an officer before a battle takes 0, not enter, so Select sends 0
   alone. At the command prompt, 0 then enter asks whether to end the month.

   Esc does nothing anywhere in the game. Enter on an empty prompt goes back
   one menu, and Backspace deletes the last typed digit, so East sends
   Backspace. A battle menu takes its digit alone; an enter after it goes back
   out of the menu the digit opened. *)
let samguk3 =
  {toml|[BTN_SOUTH]
keys = ["return"]
label = "결정·뒤로"

[BTN_EAST]
keys = ["backspace"]
label = "지우기"

[BTN_NORTH]
keys = ["y"]
label = "예 (Y)"

[BTN_WEST]
keys = ["n"]
label = "아니오 (N)"

[BTN_DPAD_UP]
keys = ["8"]
label = "위 (8)"

[BTN_DPAD_DOWN]
keys = ["2"]
label = "아래 (2)"

[BTN_DPAD_LEFT]
keys = ["7"]
label = "왼쪽 위 (7)"

[BTN_DPAD_RIGHT]
keys = ["9"]
label = "오른쪽 위 (9)"

[BTN_TL]
keys = ["1"]
label = "왼쪽 아래 (1)"

[BTN_TR]
keys = ["3"]
label = "오른쪽 아래 (3)"

[BTN_START]
keys = ["space"]
label = "아무 키"

[BTN_SELECT]
keys = ["0"]
label = "0 입력 (배치)"
|toml}

(* Keyed by the saves name, the inventory name the sangokushi-3 Skill loads
   the game under. *)
let builtin_layouts = [ ("samguk3", samguk3) ]

(* The saves name becomes a file name here. Inventory names carry no path and
   no dot (masc_dos_load refuses them), so anything else did not come from
   the inventory. *)
let is_file_component name =
  name <> ""
  && String.equal (Filename.basename name) name
  && not (String.contains name '.')

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
      match List.assoc_opt saves_name builtin_layouts with
      | Some contents -> parsed Builtin contents
      | None -> Ok None
