module Table = Masc_tui_model_runtime_table
module Edit_text = Toml_line_editor

type mode = Edit | Copy
type field = Name | Context | Effort | Temperature | Output
let fields = [Name; Context; Effort; Temperature; Output]
type t = { mode : mode; source : Table.row; values : (field * string) list;
           selected : int; error : string option }
type outcome = Editing of t | Cancelled | Submit of t
let text = function None -> "" | Some n -> string_of_int n
let create mode (source : Table.row) =
  { mode; source; selected = (match mode with Copy -> 0 | Edit -> 1); error = None;
    values = [Name, (source.model ^ (match mode with Copy -> "-copy" | Edit -> ""));
      Context, text (Option.map snd source.context);
      Effort, Option.value ~default:"" source.reasoning_effort;
      Temperature, Option.value ~default:"" source.temperature;
      Output, text source.max_tokens] }
let value t field = List.assoc field t.values
let focused t = List.nth fields t.selected
let put t content = { t with values = List.map (fun (field, old) ->
  field, if field = focused t then content else old) t.values; error = None }
let refused t error = { t with error = Some error }
let clean text = String.concat "" (String.split_on_char '\n' text)
  |> String.to_seq |> Seq.filter (fun c -> Char.code c >= 32 && c <> '\127') |> String.of_seq
let paste t text = put t (value t (focused t) ^ clean text)
let key t key =
  let first = match t.mode with Edit -> 1 | Copy -> 0 in
  let move delta = Editing { t with selected = max first (min (List.length fields - 1) (t.selected + delta)) } in
  match key with
  | "esc" | "escape" -> Cancelled
  | "up" -> move (-1)
  | "down" | "tab" | "\t" -> move 1
  | ("enter" | "\r" | "\n") when t.selected = List.length fields - 1 -> Submit t
  | "enter" | "\r" | "\n" -> move 1
  | "ctrl-u" | "\021" -> Editing (put t "")
  | "backspace" | "\127" | "\b" ->
    let current = value t (focused t) in
    let rec start n = if n > 0 && Char.code current.[n] land 0xc0 = 0x80 then start (n-1) else n in
    Editing (put t (if current = "" then "" else String.sub current 0 (start (String.length current - 1))))
  | key when String.length key > 0 && String.length key = Uchar.utf_decode_length (String.get_utf_8_uchar key 0) -> Editing (paste t key)
  | _ -> Editing t

let rows ~width ~height t =
  let wrap = Masc_tui_message_layout.wrap_words ~max_cells:(max 1 width) in
  let heading = (match t.mode with Edit -> "Edit model" | Copy -> "Copy model") ^ " · " ^ t.source.provider in
  let label = function Name -> "Variant name" | Context -> "Context tokens" | Effort -> "Reasoning effort" | Temperature -> "Temperature" | Output -> "Max output tokens" in
  let field_rows = List.mapi (fun i field ->
    Printf.sprintf "%s %-17s %s" (if i = t.selected then ">" else " ") (label field)
      (value t field ^ if i = t.selected then "_" else "")) fields in
  let hint = "Tab/↑/↓ fields · Ctrl-U clear · Enter next/save · Esc cancel" in
  let notes = (match t.mode with
    | Copy -> "Same account and API model; independent settings. Add the saved variant to a Lane to use it."
    | Edit -> "Context/output apply to this account. Effort/temperature affect every account sharing this model; use Copy for independent settings.") in
  let content = wrap heading @ List.concat_map wrap field_rows @ wrap notes in
  (* Keep navigation visible even when a server error spans many rows. The
     field window, error prefix and key hint share one bounded height. *)
  let height = max 0 height in
  let hints = wrap hint in
  let hints = if List.length hints < height then hints
    else List.take height (wrap "Esc cancel · Enter next/save") in
  let available = max 0 (height - List.length hints) in
  let errors = match t.error with None -> [] | Some error -> wrap ("Error: " ^ error) in
  let error_room = max 0 (available - (if available > 1 then 1 else 0)) in
  let errors = if List.length errors <= error_room then errors
    else if error_room = 0 then []
    else if error_room = 1 then List.take 1 errors
    else List.take (error_room - 1) errors
      @ [Masc_tui_message_layout.fit_middle (max 1 width) "… error continues; edit or Esc"] in
  let room = max 0 (available - List.length errors) in
  let selected_line = List.length (wrap heading) + List.fold_left (fun n row -> n + List.length (wrap row)) 0 (List.take t.selected field_rows) in
  let first = max 0 (selected_line - room + 1) in
  List.take room (List.drop first content) @ errors @ hints

let path parts = String.concat "." (List.map Edit_text.render_key parts)
let errors errors = String.concat "; " (List.map (fun (e:Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors)
let ( let* ) = Result.bind
let optional_positive name text =
  if text = "" then Ok None else match int_of_string_opt text with
    | Some n when n > 0 -> Ok (Some n) | _ -> Error (name ^ " must be a positive integer, or blank")
let optional_float text = if text = "" then Ok None else match float_of_string_opt text with
  | Some n when Float.is_finite n -> Ok (Some n) | _ -> Error "Temperature must be a finite number, or blank"

(* Copy structural table subtrees, including capability tables and multiline
   values. Header-like text inside a value is never interpreted as structure. *)
let copy_tables lines ~from ~into =
  let prefix parts = List.take (List.length from) parts = from in
  let _, copied = List.fold_left (fun (taking, acc) (line, structural) ->
    match if structural then Edit_text.header_of_line line else None with
    | Some (Edit_text.Table parts) | Some (Edit_text.Table_array parts) as header ->
      if prefix parts then
        let array = match header with Some (Edit_text.Table_array _) -> true | _ -> false in
        let new_parts = into @ List.drop (List.length from) parts in
        let line = (if array then "[[" else "[") ^ path new_parts ^ (if array then "]]" else "]")
          ^ Option.value ~default:"" (Edit_text.header_trailing_comment line) in
        true, line :: acc
      else false, acc
    | None -> taking, if taking then line :: acc else acc)
    (false, []) (List.combine lines (Edit_text.structural_lines lines)) in
  List.rev copied

let apply t current =
  let* config = Runtime_toml.parse_string current |> Result.map_error errors in
  let* source = match List.find_opt (fun (m:Runtime_schema.model_spec) -> m.id = t.source.model) config.models with
    | Some model -> Ok model | None -> Error "The source model no longer exists; reload Models" in
  let* () = if List.exists (fun (b:Runtime_schema.binding) -> b.provider_id = t.source.provider && b.model_id = t.source.model) config.bindings
    then Ok () else Error "The account/model binding no longer exists; reload Models" in
  let* toml = Otoml.Parser.from_string_result current in
  let lines, _ = Edit_text.split_lines current in
  let explicit_table parts =
    List.exists (fun (line, structural) -> structural &&
      match Edit_text.header_of_line line with
      | Some (Edit_text.Table found) -> List.equal String.equal found parts
      | Some (Edit_text.Table_array _) | None -> false)
      (List.combine lines (Edit_text.structural_lines lines)) in
  let require_editable parts label =
    match Otoml.find_opt toml Fun.id parts with
    | Some _ when not (explicit_table parts) ->
      Error ("This " ^ label ^ " uses inline or dotted TOML; expand its table in the source before editing or copying")
    | Some _ | None -> Ok () in
  let* () = require_editable [Runtime_toml_namespace.(key Models); source.id] "model" in
  let* () = require_editable [t.source.provider; t.source.model] "binding" in
  let name = value t Name in
  let* () = match t.mode with
    | Copy when String.trim name = "" || String.trim name <> name -> Error "Enter a nonempty variant name without surrounding spaces"
    | Copy when List.exists (fun (m:Runtime_schema.model_spec) -> m.id = name) config.models -> Error "This variant name already exists"
    | Copy | Edit -> Ok () in
  let* context = optional_positive "Context" (value t Context) in
  let* output = optional_positive "Max output" (value t Output) in
  let* temperature = optional_float (value t Temperature) in
  let effort = value t Effort in
  let* () = if effort = "" || Option.is_some (Llm_provider.Reasoning_effort.of_string effort) then Ok ()
    else Error "Unknown reasoning effort; use a supported effort or leave blank" in
  let model_path = path [Runtime_toml_namespace.(key Models); name] in
  let binding_path = path [t.source.provider; name] in
  let* draft = match t.mode with
    | Edit -> Ok current
    | Copy ->
      let lines, _ = Edit_text.split_lines current in
      let copied_model = copy_tables lines ~from:[Runtime_toml_namespace.(key Models); source.id]
        ~into:[Runtime_toml_namespace.(key Models); name] in
      if copied_model = [] then Error "This model uses inline TOML; expand its model table before copying" else
      let copied_binding = copy_tables lines ~from:[t.source.provider; source.id] ~into:[t.source.provider; name] in
      let* copied_binding = if copied_binding <> [] then Ok copied_binding else
        let* toml = Otoml.Parser.from_string_result current in
        match Otoml.find_opt toml Fun.id [t.source.provider; source.id] with
        | Some _ -> Error "This binding uses inline TOML; expand its binding table before copying"
        | None -> Ok ["[" ^ binding_path ^ "]"] in
      let draft = current ^ "\n" ^ String.concat "\n" (copied_model @ copied_binding) ^ "\n" in
      let draft = Edit_text.edit_table_scalar draft ~path:model_path ~key:"api-name" ~value:(Some source.api_name) in
      let draft = Edit_text.edit_table_bool draft ~path:binding_path ~key:"is-default" ~value:false in
      Ok (Edit_text.edit_table_bool draft ~path:binding_path ~key:"wizard-default" ~value:false) in
  let set_int text key value = match value with
    | Some value -> Edit_text.edit_table_int text ~path:binding_path ~key ~value
    | None -> Edit_text.edit_table_scalar text ~path:binding_path ~key ~value:None in
  let draft = if t.mode = Edit && context = Option.map snd t.source.context then draft
    else set_int draft "max-context" context in
  let draft = if output = t.source.max_tokens then draft else set_int draft "max-tokens" output in
  let draft = match Runtime_schema.provider_of_id config t.source.provider with
    | Some ({ api_format = Runtime_schema.Ollama_api; _ } as provider)
      when t.mode = Copy || context <> Option.map snd t.source.context ->
      let requested = match context, provider.max_context with
        | Some value, _ | None, Some value -> Some value
        | None, None -> source.max_context in
      set_int draft "num-ctx" requested
    | _ -> draft in
  let draft = if effort = Option.value ~default:"" t.source.reasoning_effort then draft else
    Edit_text.edit_table_scalar draft ~path:model_path ~key:"reasoning-effort" ~value:(if effort = "" then None else Some effort) in
  let draft = if value t Temperature = Option.value ~default:"" t.source.temperature then draft else match temperature with
    | Some value -> Edit_text.edit_table_float draft ~path:model_path ~key:"temperature" ~value
    | None -> Edit_text.edit_table_scalar draft ~path:model_path ~key:"temperature" ~value:None in
  Runtime_toml.parse_string draft |> Result.map_error errors |> Result.map (fun _ -> draft)
