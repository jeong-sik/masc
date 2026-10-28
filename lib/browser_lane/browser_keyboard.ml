type modifier = Control | Meta | Alt | Shift
type key = Named of Browser_action.key | Character of Uchar.t
type t = { modifiers : modifier list; key : key }
let modifier_name = function Control -> "Control" | Meta -> "Meta" | Alt -> "Alt" | Shift -> "Shift"
let named = [Browser_action.Enter;Tab;Escape;Backspace;Delete;ArrowUp;ArrowDown;ArrowLeft;ArrowRight;Home;End]
open Result.Syntax
let w3c_reserved value = let scalar = Uchar.to_int value in scalar >= 0xe000 && scalar <= 0xe05d
let validate_text text =
  let rec scan index =
    if index = String.length text then Ok () else
    let decoded = String.get_utf_8_uchar text index in
    if not (Uchar.utf_decode_is_valid decoded) then Error "text must contain valid Unicode"
    else if let value = Uchar.to_int (Uchar.utf_decode_uchar decoded) in value < 0x20 || value = 0x7f
    then Error "type_text cannot contain control characters; use explicit press_key for Enter or Tab"
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
      else if w3c_reserved value then Error "WebDriver-reserved scalars require a named key"
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
let webdriver_modifier = function Control -> "\xee\x80\x89" | Meta -> "\xee\x80\xbd"
  | Alt -> "\xee\x80\x8a" | Shift -> "\xee\x80\x88"
let webdriver_key = function Named key -> Browser_action.webdriver_key key | Character _ as key -> key_text key
let event kind value = `Assoc ["type", `String kind; "value", `String value]
let source ~id actions = `List [`Assoc ["type", `String "key";"id", `String id;"actions", `List actions]]
let input_source ~id chord =
  let values = List.map webdriver_modifier chord.modifiers @ [webdriver_key chord.key] in
  source ~id (List.map (event "keyDown") values @ List.map (event "keyUp") (List.rev values))
let text_source ~id text =
  let* () = validate_text text in
  let rec collect index events =
    if index = String.length text then Ok (source ~id (List.rev events)) else
    let decoded = String.get_utf_8_uchar text index in
    if w3c_reserved (Uchar.utf_decode_uchar decoded) then Error "native WebDriver text cannot contain reserved key scalars" else
    let length = Uchar.utf_decode_length decoded in
    let value = String.sub text index length in
    collect (index+length) (event "keyUp" value :: event "keyDown" value :: events) in
  collect 0 []
