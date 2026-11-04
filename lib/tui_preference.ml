(* The [tui] table of runtime.toml and the changes a terminal reader makes to
   it (RFC-0482 §3.1). The server parses a change at its door and writes it
   with [edit]; the terminal reads the same keys back through [Key]. *)

let table = Runtime_toml_namespace.(key Tui)

module Key = struct
  type t =
    | Opening
    | Opening_keeper
    | Last_chat_keeper
    | Theme
    | Language
    | Board_sort
    | Candle
    | Help_hint_shown

  let name = function
    | Opening -> "opening"
    | Opening_keeper -> "opening_keeper"
    | Last_chat_keeper -> "last_chat_keeper"
    | Theme -> "theme"
    | Language -> "language"
    | Board_sort -> "board_sort"
    | Candle -> "candle"
    | Help_hint_shown -> "help_hint_shown"

  let doc_path key = table ^ "." ^ name key
end

type language =
  | Lang_ko
  | Lang_en
[@@deriving enumerate]

let language_to_string = function
  | Lang_ko -> "ko"
  | Lang_en -> "en"

let language_of_string value =
  let value = String.lowercase_ascii (String.trim value) in
  List.find_opt (fun language -> String.equal (language_to_string language) value) all_of_language

type candle =
  | Painted
  | Dotted
[@@deriving enumerate]

let candle_to_string = function
  | Painted -> "painted"
  | Dotted -> "dotted"

let candle_of_string value =
  List.find_opt (fun candle -> String.equal (candle_to_string candle) value) all_of_candle

type opening =
  | Overview
  | Last of Keeper_id.Keeper_name.t option
  | Keeper of Keeper_id.Keeper_name.t

let keeper_name_of_doc doc key =
  let path = Key.doc_path key in
  match List.assoc_opt path doc with
  | None -> Ok None
  | Some (Keeper_toml_loader.Toml_string name) ->
    (match Keeper_id.Keeper_name.of_string name with
     | Ok name -> Ok (Some name)
     | Error reason -> Error (Printf.sprintf "Invalid [%s].%s: %s" table (Key.name key) reason))
  | Some (Keeper_toml_loader.Toml_int _)
  | Some (Keeper_toml_loader.Toml_float _)
  | Some (Keeper_toml_loader.Toml_bool _)
  | Some (Keeper_toml_loader.Toml_string_array _)
  | Some (Keeper_toml_loader.Toml_array _)
  | Some (Keeper_toml_loader.Toml_table _)
  | Some (Keeper_toml_loader.Toml_inline_table _)
  | Some (Keeper_toml_loader.Toml_table_array _)
  | Some (Keeper_toml_loader.Toml_offset_datetime _)
  | Some (Keeper_toml_loader.Toml_local_datetime _)
  | Some (Keeper_toml_loader.Toml_local_date _)
  | Some (Keeper_toml_loader.Toml_local_time _) ->
    Error (Printf.sprintf "[%s].%s must be a Keeper name string" table (Key.name key))

let opening_keeper_of_doc doc = keeper_name_of_doc doc Key.Opening_keeper
let last_chat_keeper_of_doc doc = keeper_name_of_doc doc Key.Last_chat_keeper

let opening_of_doc doc =
  match List.assoc_opt (Key.doc_path Key.Opening) doc with
  | None | Some (Keeper_toml_loader.Toml_string "overview") -> Ok Overview
  | Some (Keeper_toml_loader.Toml_string "last") ->
    (match last_chat_keeper_of_doc doc with
     | Ok (Some name) -> Ok (Last (Some name))
     | Ok None -> Result.map (fun name -> Last name) (opening_keeper_of_doc doc)
     | Error reason -> Error reason)
  | Some (Keeper_toml_loader.Toml_string "keeper") ->
    (match opening_keeper_of_doc doc with
     | Ok (Some name) -> Ok (Keeper name)
     | Ok None -> Error "[tui].opening = keeper needs opening_keeper"
     | Error reason -> Error reason)
  | Some (Keeper_toml_loader.Toml_string value) -> Error ("Unknown [tui].opening: " ^ value)
  | Some (Keeper_toml_loader.Toml_int _)
  | Some (Keeper_toml_loader.Toml_float _)
  | Some (Keeper_toml_loader.Toml_bool _)
  | Some (Keeper_toml_loader.Toml_string_array _)
  | Some (Keeper_toml_loader.Toml_array _)
  | Some (Keeper_toml_loader.Toml_table _)
  | Some (Keeper_toml_loader.Toml_inline_table _)
  | Some (Keeper_toml_loader.Toml_table_array _)
  | Some (Keeper_toml_loader.Toml_offset_datetime _)
  | Some (Keeper_toml_loader.Toml_local_datetime _)
  | Some (Keeper_toml_loader.Toml_local_date _)
  | Some (Keeper_toml_loader.Toml_local_time _) ->
    Error "[tui].opening must be overview, last, or keeper"

type change =
  | Chat_visited of Keeper_id.Keeper_name.t
  | Theme_chosen of string option
  | Language_chosen of language
  | Board_sort_chosen of Board_dispatch.sort_order
  | Candle_chosen of candle
  | Help_hint_retired

let scalar content key value = Toml_line_editor.edit_table_scalar content ~path:table ~key:(Key.name key) ~value

let edit change content =
  match change with
  | Chat_visited keeper ->
    let name = Some (Keeper_id.Keeper_name.to_string keeper) in
    let content = scalar content Key.Last_chat_keeper name in
    (* Remember the target as the opening one only while the reader opens on
       the last chat; the other openings keep their own target. *)
    (match Keeper_toml_loader.parse_toml content with
     | Ok doc ->
       (match opening_of_doc doc with
        | Ok (Last _) -> scalar content Key.Opening_keeper name
        | Ok (Overview | Keeper _) | Error _ -> content)
     | Error _ -> content)
  | Theme_chosen theme -> scalar content Key.Theme theme
  | Language_chosen language -> scalar content Key.Language (Some (language_to_string language))
  | Board_sort_chosen sort ->
    scalar content Key.Board_sort (Some (Board_dispatch.sort_order_to_string sort))
  | Candle_chosen candle -> scalar content Key.Candle (Some (candle_to_string candle))
  | Help_hint_retired ->
    Toml_line_editor.edit_table_bool content ~path:table ~key:(Key.name Key.Help_hint_shown)
      ~value:true

(* The wire form: one object per change, its kind in [change] and, for a
   kind that carries a value, one more field. *)
type valued_kind =
  | Chat_visited_kind
  | Theme_kind
  | Language_kind
  | Board_sort_kind
  | Candle_kind
[@@deriving enumerate]

type kind =
  | Valued of valued_kind
  | Help_hint_kind
[@@deriving enumerate]

let valued_kind_name = function
  | Chat_visited_kind -> "chat_visited"
  | Theme_kind -> "theme"
  | Language_kind -> "language"
  | Board_sort_kind -> "board_sort"
  | Candle_kind -> "candle"

let kind_name = function
  | Valued valued -> valued_kind_name valued
  | Help_hint_kind -> "help_hint_retired"

let valued_field = function
  | Chat_visited_kind -> "keeper"
  | Theme_kind -> "theme"
  | Language_kind -> "language"
  | Board_sort_kind -> "sort"
  | Candle_kind -> "candle"

let kind_of_change = function
  | Chat_visited _ -> Valued Chat_visited_kind
  | Theme_chosen _ -> Valued Theme_kind
  | Language_chosen _ -> Valued Language_kind
  | Board_sort_chosen _ -> Valued Board_sort_kind
  | Candle_chosen _ -> Valued Candle_kind
  | Help_hint_retired -> Help_hint_kind

let kind_field_name = "change"
let change_kind change = kind_name (kind_of_change change)

let optional_string = function
  | None -> `Null
  | Some value -> `String value

let change_to_yojson change =
  let valued kind value = [ valued_field kind, value ] in
  let value_fields =
    match change with
    | Chat_visited keeper ->
      valued Chat_visited_kind (`String (Keeper_id.Keeper_name.to_string keeper))
    | Theme_chosen theme -> valued Theme_kind (optional_string theme)
    | Language_chosen language -> valued Language_kind (`String (language_to_string language))
    | Board_sort_chosen sort ->
      valued Board_sort_kind (`String (Board_dispatch.sort_order_to_string sort))
    | Candle_chosen candle -> valued Candle_kind (`String (candle_to_string candle))
    | Help_hint_retired -> []
  in
  `Assoc ((kind_field_name, `String (change_kind change)) :: value_fields)

let ( let* ) = Result.bind

let string_value ~field = function
  | `String value -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
    Error (field ^ " must be a string")

(* A theme name; [null] withdraws the stored one. A blank name is neither a
   pick nor a withdrawal, and blanks around a name are not part of any name. *)
let name_or_null ~field = function
  | `Null -> Ok None
  | `String value when String.equal (String.trim value) "" -> Error (field ^ " must not be blank")
  | `String value when not (String.equal (String.trim value) value) ->
    Error (field ^ " must not start or end with blanks")
  | `String value -> Ok (Some value)
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
    Error (field ^ " must be a string or null")

let parsed ~field of_string value =
  let* text = string_value ~field value in
  match of_string text with
  | Some parsed -> Ok parsed
  | None -> Error (Printf.sprintf "unknown %s: %s" field text)

let change_of_value kind ~field value =
  match kind with
  | Chat_visited_kind ->
    let* name = string_value ~field value in
    Result.map (fun keeper -> Chat_visited keeper) (Keeper_id.Keeper_name.of_string name)
  | Theme_kind -> Result.map (fun theme -> Theme_chosen theme) (name_or_null ~field value)
  | Language_kind ->
    Result.map (fun language -> Language_chosen language) (parsed ~field language_of_string value)
  | Board_sort_kind ->
    Result.map
      (fun sort -> Board_sort_chosen sort)
      (parsed ~field Board_dispatch.sort_order_of_string_opt value)
  | Candle_kind -> Result.map (fun candle -> Candle_chosen candle) (parsed ~field candle_of_string value)

let rec first_repeated = function
  | [] -> None
  | (name, _) :: rest -> if List.mem_assoc name rest then Some name else first_repeated rest

let change_of_yojson = function
  | `Assoc fields ->
    let* () =
      match first_repeated fields with
      | None -> Ok ()
      | Some name -> Error ("repeated field " ^ name)
    in
    let* kind =
      match List.assoc_opt kind_field_name fields with
      | None -> Error (kind_field_name ^ " is required")
      | Some value ->
        let* name = string_value ~field:kind_field_name value in
        (match List.find_opt (fun kind -> String.equal (kind_name kind) name) all_of_kind with
         | Some kind -> Ok kind
         | None -> Error ("unknown change " ^ name))
    in
    (match kind, List.remove_assoc kind_field_name fields with
     | Help_hint_kind, [] -> Ok Help_hint_retired
     | Valued valued, [ (name, value) ] when String.equal name (valued_field valued) ->
       change_of_value valued ~field:name value
     | Valued valued, [] -> Error (valued_field valued ^ " is required")
     | (Help_hint_kind | Valued _), (name, _) :: _ ->
       Error (Printf.sprintf "unknown field %s for %s" name (kind_name kind)))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "a change must be an object"
