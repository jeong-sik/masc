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

type source =
  | Workspace
  | Builtin

let source_to_string = function
  | Workspace -> "workspace"
  | Builtin -> "builtin"


let to_json ~saves_name ~source layout =
  `Assoc ["saves_name", `String saves_name; "source", `String (source_to_string source);
    "buttons", `List (List.map (fun (button, {keys;label}) ->
      `Assoc ["button", `String (button_to_string button); "label", `String label;
        "keys", `List (List.map (fun key -> `String key) keys)]) (bindings layout))]

let of_json json =
  let ( let* ) = Result.bind in
  let fields expected = function
    | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare expected -> Ok fields
    | _ -> Error "invalid or duplicate pad layout fields" in
  let nonempty = function `String s when String.trim s <> "" -> Ok s | _ -> Error "pad value must be a nonempty string" in
  let* top = fields ["saves_name";"source";"buttons"] json in
  let* saves_name = nonempty (List.assoc "saves_name" top) in
  let* source = match List.assoc "source" top with
    | `String "workspace" -> Ok Workspace | `String "builtin" -> Ok Builtin
    | _ -> Error "invalid pad layout source" in
  let* items = match List.assoc "buttons" top with `List items -> Ok items | _ -> Error "pad buttons must be an array" in
  let* layout = List.fold_left (fun acc item ->
    let* layout = acc in
    let* item = fields ["button";"label";"keys"] item in
    let* name = nonempty (List.assoc "button" item) in
    let* button = button_of_string name in
    let* label = nonempty (List.assoc "label" item) in
    let* keys = match List.assoc "keys" item with
      | `List (_::_ as items) -> List.fold_right (fun item rest ->
          let* key = nonempty item in let* rest = rest in Ok (key::rest)) items (Ok [])
      | _ -> Error "pad keys must be a nonempty array" in
    if List.mem_assoc button layout then Error "duplicate pad button"
    else Ok ((button,{keys;label})::layout)) (Ok []) items in
  Ok (saves_name,source,List.rev layout)
