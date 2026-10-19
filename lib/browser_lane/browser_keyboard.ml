type modifier = Control | Meta | Alt | Shift
type key = Named of Browser_action.key | Character of Uchar.t
type t = { modifiers : modifier list; key : key }
let modifier_name = function Control -> "Control" | Meta -> "Meta" | Alt -> "Alt" | Shift -> "Shift"
let named = [Browser_action.Enter;Tab;Escape;Backspace;Delete;ArrowUp;ArrowDown;ArrowLeft;ArrowRight;Home;End]
let ( let* ) = Result.bind
let validate_text text =
  let rec scan index =
    if index = String.length text then Ok () else
    let decoded = String.get_utf_8_uchar text index in
    if not (Uchar.utf_decode_is_valid decoded) then Error "text must contain valid Unicode"
    else scan (index + Uchar.utf_decode_length decoded) in
  scan 0
let parse_key text =
  match List.find_opt (fun key -> Browser_action.key_name key = text) named with
  | Some key -> Ok (Named key)
  | None ->
    if text = "" then Error "key must be a named key or one Unicode scalar" else
    let decoded = String.get_utf_8_uchar text 0 in
    if not (Uchar.utf_decode_is_valid decoded) || Uchar.utf_decode_length decoded <> String.length text
    then Error "key must be a named key or one Unicode scalar"
    else let value = Uchar.utf_decode_uchar decoded in
      if Uchar.to_int value < 0x20 || Uchar.to_int value = 0x7f
      then Error "control characters require a named key"
      else Ok (Character value)
let parse_modifier = function
  | "Control" -> Ok Control | "Meta" -> Ok Meta | "Alt" -> Ok Alt | "Shift" -> Ok Shift
  | _ -> Error "modifiers must be Control, Meta, Alt, or Shift"
let of_wire ~key ~modifiers =
  let* key = parse_key key in
  let rec collect seen = function
    | [] -> Ok (List.rev seen)
    | name :: rest -> let* modifier = parse_modifier name in
      if List.mem modifier seen then Error "duplicate keyboard modifier"
      else collect (modifier :: seen) rest in
  let* modifiers = collect [] modifiers in
  Ok {key;modifiers}
let key_text = function
  | Named key -> Browser_action.key_name key
  | Character value ->
    let text = Bytes.create (Uchar.utf_8_byte_length value) in
    ignore (Bytes.set_utf_8_uchar text 0 value);
    Bytes.to_string text
let to_json_fields chord = ["key", `String (key_text chord.key);
  "modifiers", `List (List.map (fun modifier -> `String (modifier_name modifier)) chord.modifiers)]
