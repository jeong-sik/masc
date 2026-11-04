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
    | Reduce_motion
    | Lift_colours
    | Table_frame
    | Hints_visible
    | Coalesce_queued_input
    | User_input_priority_next
    | Midi_soundfont
    | Audio_input_device

  let name = function
    | Opening -> "opening"
    | Opening_keeper -> "opening_keeper"
    | Last_chat_keeper -> "last_chat_keeper"
    | Theme -> "theme"
    | Language -> "language"
    | Board_sort -> "board_sort"
    | Candle -> "candle"
    | Help_hint_shown -> "help_hint_shown"
    | Reduce_motion -> "reduce_motion"
    | Lift_colours -> "lift_colours"
    | Table_frame -> "table_frame"
    | Hints_visible -> "hints_visible"
    | Coalesce_queued_input -> "coalesce_queued_input"
    | User_input_priority_next -> "user_input_priority_next"
    | Midi_soundfont -> "midi_soundfont"
    | Audio_input_device -> "audio_input_device"

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

(* The read side: what a terminal reader starts with. The rules are the ones
   the terminal used when it read the file itself, so moving the read to the
   server changes where the file is found, not what it says. *)
type settings =
  { opening : (opening, string) result
  ; last_chat_keeper : (Keeper_id.Keeper_name.t option, string) result
  ; theme : string option
  ; language : string option
  ; board_sort : string option
  ; candle : string option
  ; reduce_motion : bool option
  ; lift_colours : bool option
  ; table_frame : bool option
  ; hints_visible : bool option
  ; help_hint_shown : bool option
  ; coalesce_queued_input : bool option
  ; send_on_stop : bool option
  ; user_input_priority_next : bool option
  ; midi_soundfont : string option
  ; audio_input_device : string option
  }

let string_of_doc doc key = Keeper_toml_loader.toml_string_opt doc (Key.doc_path key)
let bool_of_doc doc key = Keeper_toml_loader.toml_bool_opt doc (Key.doc_path key)

(* A blank device is "no stored pick", like an absent one: a blank name passed
   on would reach the capture as a device to open. *)
let audio_input_device_of_doc doc =
  match string_of_doc doc Key.Audio_input_device with
  | Some device when not (String.equal (String.trim device) "") -> Some (String.trim device)
  | Some _ | None -> None

(* [voice.stt].send_on_stop, read through the parser that owns the [voice]
   section. A [voice] section that does not parse reads as off: this is not
   where a broken voice config is reported, and off keeps the step where the
   operator confirms a send. *)
let send_on_stop_of_text text =
  match Voice_config.parse_runtime_toml_text text with
  | Ok (Some config) -> Option.map (fun stt -> stt.Voice_config.send_on_stop) config.Voice_config.stt
  | Ok None | Error _ -> None

let settings_of_reading reading =
  let text =
    match reading with
    | Ok text -> text
    | Error _ -> None
  in
  (* The reason the history is unavailable says which step failed and no
     more: a parse error quotes the file's own keys and tables, and a read
     error names its path, neither of which belongs to the [tui] table this
     answer is limited to. The server logs the detail. *)
  let doc_reading =
    match reading with
    | Ok None -> Ok None
    | Error _ -> Error "runtime.toml could not be read"
    | Ok (Some text) ->
      (match Keeper_toml_loader.parse_toml text with
       | Ok doc -> Ok (Some doc)
       | Error detail ->
         Log.Server.warn "tui preferences: runtime.toml does not parse: %s" detail;
         Error "runtime.toml does not parse")
  in
  let doc =
    match doc_reading with
    | Ok doc -> doc
    | Error _ -> None
  in
  let read extract = Option.bind doc extract in
  { opening =
      (match doc with
       | Some doc -> opening_of_doc doc
       | None -> Ok Overview)
  ; last_chat_keeper =
      (match doc_reading with
       | Ok (Some doc) -> last_chat_keeper_of_doc doc
       | Ok None -> Ok None
       | Error reason -> Error ("Conversation history unavailable: " ^ reason))
  ; theme = read (fun doc -> string_of_doc doc Key.Theme)
  ; language = read (fun doc -> string_of_doc doc Key.Language)
  ; board_sort = read (fun doc -> string_of_doc doc Key.Board_sort)
  ; candle = read (fun doc -> string_of_doc doc Key.Candle)
  ; reduce_motion = read (fun doc -> bool_of_doc doc Key.Reduce_motion)
  ; lift_colours = read (fun doc -> bool_of_doc doc Key.Lift_colours)
  ; table_frame = read (fun doc -> bool_of_doc doc Key.Table_frame)
  ; hints_visible = read (fun doc -> bool_of_doc doc Key.Hints_visible)
  ; help_hint_shown = read (fun doc -> bool_of_doc doc Key.Help_hint_shown)
  ; coalesce_queued_input = read (fun doc -> bool_of_doc doc Key.Coalesce_queued_input)
  ; send_on_stop = Option.bind text send_on_stop_of_text
  ; user_input_priority_next = read (fun doc -> bool_of_doc doc Key.User_input_priority_next)
  ; midi_soundfont = read (fun doc -> string_of_doc doc Key.Midi_soundfont)
  ; audio_input_device = read audio_input_device_of_doc
  }

let read_settings ~path =
  let reading =
    match Unix.stat path with
    | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> Ok None
    | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
    | (_ : Unix.stats) ->
      (try Ok (Some (Fs_compat.load_file path)) with
       | Sys_error reason -> Error reason)
  in
  (match reading with
   | Error detail -> Log.Server.warn "tui preferences: %s could not be read: %s" path detail
   | Ok (Some _ | None) -> ());
  settings_of_reading reading

let settings_schema = "masc.tui-preferences/v1"

let keeper_json = function
  | None -> `Null
  | Some keeper -> `String (Keeper_id.Keeper_name.to_string keeper)

let opening_mode = function
  | Overview -> "overview"
  | Last _ -> "last"
  | Keeper _ -> "keeper"

let opening_to_yojson = function
  | Error reason -> `Assoc [ "error", `String reason ]
  | Ok (Overview as opening) -> `Assoc [ "mode", `String (opening_mode opening) ]
  | Ok (Last keeper as opening) ->
    `Assoc [ "mode", `String (opening_mode opening); "keeper", keeper_json keeper ]
  | Ok (Keeper keeper as opening) ->
    `Assoc [ "mode", `String (opening_mode opening); "keeper", keeper_json (Some keeper) ]

let last_chat_keeper_to_yojson = function
  | Error reason -> `Assoc [ "error", `String reason ]
  | Ok keeper -> `Assoc [ "keeper", keeper_json keeper ]

let string_option = function
  | None -> `Null
  | Some value -> `String value

let bool_option = function
  | None -> `Null
  | Some value -> `Bool value

let settings_fields settings =
    [ "schema", `String settings_schema
    ; "opening", opening_to_yojson settings.opening
    ; "last_chat_keeper", last_chat_keeper_to_yojson settings.last_chat_keeper
    ; Key.name Key.Theme, string_option settings.theme
    ; Key.name Key.Language, string_option settings.language
    ; Key.name Key.Board_sort, string_option settings.board_sort
    ; Key.name Key.Candle, string_option settings.candle
    ; Key.name Key.Reduce_motion, bool_option settings.reduce_motion
    ; Key.name Key.Lift_colours, bool_option settings.lift_colours
    ; Key.name Key.Table_frame, bool_option settings.table_frame
    ; Key.name Key.Hints_visible, bool_option settings.hints_visible
    ; Key.name Key.Help_hint_shown, bool_option settings.help_hint_shown
    ; Key.name Key.Coalesce_queued_input, bool_option settings.coalesce_queued_input
    ; "send_on_stop", bool_option settings.send_on_stop
    ; Key.name Key.User_input_priority_next, bool_option settings.user_input_priority_next
    ; Key.name Key.Midi_soundfont, string_option settings.midi_soundfont
    ; Key.name Key.Audio_input_device, string_option settings.audio_input_device
    ]

let settings_to_yojson settings = `Assoc (settings_fields settings)

let keeper_of_json ~field = function
  | `Null -> Ok None
  | `String name -> Result.map Option.some (Keeper_id.Keeper_name.of_string name)
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
    Error (field ^ " must be a Keeper name or null")

let error_or ~field ok_of = function
  | `Assoc [ ("error", `String reason) ] -> Ok (Error reason)
  | json -> Result.map Result.ok (ok_of json) |> Result.map_error (fun detail -> field ^ ": " ^ detail)

(* Fields in name order, so a sender that orders keys differently reads the
   same. *)
let sorted_fields fields = List.sort (fun (a, _) (b, _) -> String.compare a b) fields

let opening_of_json json =
  let not_an_opening = Error "not an opening" in
  error_or ~field:"opening"
    (function
      | `Assoc fields ->
        (match sorted_fields fields with
         | [ ("mode", `String "overview") ] -> Ok Overview
         | [ ("keeper", keeper); ("mode", `String "last") ] ->
           Result.map (fun keeper -> Last keeper) (keeper_of_json ~field:"keeper" keeper)
         | [ ("keeper", keeper); ("mode", `String "keeper") ] ->
           let* keeper = keeper_of_json ~field:"keeper" keeper in
           (match keeper with
            | Some keeper -> Ok (Keeper keeper)
            | None -> Error "a keeper opening needs a Keeper")
         | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ -> not_an_opening)
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> not_an_opening)
    json

let last_chat_keeper_of_json json =
  error_or ~field:"last_chat_keeper"
    (function
      | `Assoc [ ("keeper", keeper) ] -> keeper_of_json ~field:"keeper" keeper
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ ->
        Error "not a last chat")
    json

let string_option_of_json ~field = function
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
    Error (field ^ " must be a string or null")

let bool_option_of_json ~field = function
  | `Null -> Ok None
  | `Bool value -> Ok (Some value)
  | `String _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
    Error (field ^ " must be a boolean or null")

let settings_of_yojson json =
  match json with
  | `Assoc fields ->
    let names fields = List.sort String.compare (List.map fst fields) in
    let* () =
      if
        List.equal String.equal (names fields)
          (names (settings_fields (settings_of_reading (Ok None))))
      then Ok ()
      else Error "the settings do not carry exactly the expected fields"
    in
    let field name = List.assoc name fields in
    let* () =
      match field "schema" with
      | `String schema when String.equal schema settings_schema -> Ok ()
      | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
        Error ("schema is not " ^ settings_schema)
    in
    let str key = string_option_of_json ~field:(Key.name key) (field (Key.name key)) in
    let flag key = bool_option_of_json ~field:(Key.name key) (field (Key.name key)) in
    let* opening = opening_of_json (field "opening") in
    let* last_chat_keeper = last_chat_keeper_of_json (field "last_chat_keeper") in
    let* theme = str Key.Theme in
    let* language = str Key.Language in
    let* board_sort = str Key.Board_sort in
    let* candle = str Key.Candle in
    let* reduce_motion = flag Key.Reduce_motion in
    let* lift_colours = flag Key.Lift_colours in
    let* table_frame = flag Key.Table_frame in
    let* hints_visible = flag Key.Hints_visible in
    let* help_hint_shown = flag Key.Help_hint_shown in
    let* coalesce_queued_input = flag Key.Coalesce_queued_input in
    let* send_on_stop = bool_option_of_json ~field:"send_on_stop" (field "send_on_stop") in
    let* user_input_priority_next = flag Key.User_input_priority_next in
    let* midi_soundfont = str Key.Midi_soundfont in
    let* audio_input_device = str Key.Audio_input_device in
    Ok
      { opening
      ; last_chat_keeper
      ; theme
      ; language
      ; board_sort
      ; candle
      ; reduce_motion
      ; lift_colours
      ; table_frame
      ; hints_visible
      ; help_hint_shown
      ; coalesce_queued_input
      ; send_on_stop
      ; user_input_priority_next
      ; midi_soundfont
      ; audio_input_device
      }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "the settings must be an object"
