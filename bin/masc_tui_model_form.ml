module Table = Masc_tui_model_runtime_table
module Edit_text = Toml_line_editor

type mode = Edit | Copy
type field = Name | Context | Effort | Temperature | Output
type context_choice = Preset of int | Custom
type name_choice = Suggested_name | Context_name | Operator_name
(* Operator-requested decimal token presets, not advertised model limits.
   Runtime resolves the effective context and any capability clamp. *)
let context_presets = [272000; 500000; 750000; 1000000]
let context_ring = List.map (fun tokens -> Preset tokens) context_presets @ [Custom]
let fields = [Name; Context; Effort; Temperature; Output]
type t = { mode : mode; source : Table.row; values : (field * string) list;
           selected : int; error : string option; source_revision : string option;
           context_choice : context_choice; custom_context : string; name_choice : name_choice }
type outcome = Editing of t | Cancelled | Submit of t
let text = function None -> "" | Some n -> string_of_int n
let create ?source_revision mode (source : Table.row) =
  let context = Option.map snd source.context in
  { mode; source; source_revision;
    context_choice = (match context with Some tokens when List.mem tokens context_presets -> Preset tokens | _ -> Custom);
    custom_context = text context; name_choice = Suggested_name; selected = (match mode with Copy -> 0 | Edit -> 1); error = None;
    values = [Name, (source.model ^ (match mode with Copy -> "-copy" | Edit -> ""));
      Context, text (Option.map snd source.context);
      Effort, Option.value ~default:"" source.reasoning_effort;
      Temperature, Option.value ~default:"" source.temperature;
      Output, text source.max_tokens] }
let source_revision t = t.source_revision
let value t field = List.assoc field t.values
let focused t = List.nth fields t.selected
let context_name source content =
  match int_of_string_opt content with
  | Some tokens when tokens > 0 ->
      let suffix = if tokens mod 1000000 = 0 then Printf.sprintf "%dm" (tokens / 1000000)
        else if tokens mod 1000 = 0 then Printf.sprintf "%dk" (tokens / 1000)
        else string_of_int tokens in
      Some (source.Table.model ^ "-c" ^ suffix)
  | Some _ | None -> None
let put t content =
  let field = focused t in
  let t = match field with
    | Name -> {t with name_choice=Operator_name}
    | Context -> {t with context_choice=Custom; custom_context=content}
    | Effort | Temperature | Output -> t in
  let suggested = if field=Context && t.mode=Copy && t.name_choice=Context_name
    then context_name t.source content else None in
  {t with values=List.map (fun (item, old) ->
    item, if item=field then content else if item=Name then Option.value ~default:old suggested else old) t.values;
    error=None}
let step_context t delta =
  let index = Option.value ~default:(List.length context_ring - 1)
    (List.find_index ((=) t.context_choice) context_ring) in
  let choice = List.nth context_ring ((index + delta + List.length context_ring) mod List.length context_ring) in
  let content = match choice with Preset tokens -> string_of_int tokens | Custom -> t.custom_context in
  let name_choice = match t.mode, t.name_choice with
    | Copy, (Suggested_name | Context_name) -> Context_name
    | (Edit, ((Suggested_name | Context_name | Operator_name) as choice))
    | (Copy, (Operator_name as choice)) -> choice in
  let suggested = if t.mode=Copy && name_choice=Context_name then context_name t.source content else None in
  {t with context_choice=choice; name_choice; error=None;
    values=List.map (fun (field, old) -> field,
      match field with Context -> content | Name -> Option.value ~default:old suggested
      | Effort | Temperature | Output -> old) t.values}
let refused t error = { t with error = Some error }
let clean text = String.concat "" (String.split_on_char '\n' text)
  |> String.to_seq |> Seq.filter (fun c -> Char.code c >= 32 && c <> '\127') |> String.of_seq
let paste t text = put t (value t (focused t) ^ clean text)
let key t key =
  let first = match t.mode with Edit -> 1 | Copy -> 0 in
  let move delta = Editing { t with selected = max first (min (List.length fields - 1) (t.selected + delta)) } in
  match key with
  | "esc" | "escape" -> Cancelled
  | "left" when focused t = Context -> Editing (step_context t (-1))
  | "right" when focused t = Context -> Editing (step_context t 1)
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

let rows_with_selection ?(ko = false) ?(input_locked=false) ~width ~height t =
  let say korean english = if ko then korean else english in
  let plain lines = List.map (fun line -> false, line) lines in
  let wrap = Masc_tui_message_layout.wrap_words ~max_cells:(max 1 width) in
  let heading =
    (match t.mode with
     | Edit -> say "모델 설정 편집" "Edit model"
     | Copy -> say "모델 복제" "Copy model")
    ^ " · " ^ t.source.provider
  in
  let label = function
    | Name -> say "변형 이름" "Variant name"
    | Context -> say "컨텍스트 토큰" "Context tokens"
    | Effort -> say "추론 강도" "Reasoning effort"
    | Temperature -> say "Temperature" "Temperature"
    | Output -> say "최대 출력 토큰" "Max output tokens"
  in
  let pad_label text =
    text ^ String.make (max 0 (17 - Masc_tui_message_layout.display_width text)) ' '
  in
  let field_rows = List.mapi (fun i field ->
    Printf.sprintf "%s %s %s" (if i = t.selected then "›" else " ") (pad_label (label field))
      (value t field ^ (if i = t.selected && not input_locked then "_" else "")
       ^ (if field=Context then
            (match t.context_choice with
             | Preset _ -> say " [프리셋]" " [preset]"
             | Custom -> say " [직접 입력]" " [custom]")
          else ""))) fields in
  let hint =
    if input_locked then
      say "입력 유지 · Esc:뒤로 · Ctrl-X:영수증 확인 후 복구 닫기"
        "Input retained · Esc back · Ctrl-X closes recovery after receipt"
    else
      (if focused t=Context then
         say "←/→ 272k/500k/750k/1M/직접 입력 · " "←/→ 272k/500k/750k/1M/custom · "
       else "")
      ^ say "Tab/↑/↓:필드 · Ctrl-U:지우기 · Enter:다음/저장 · Esc:취소"
          "Tab/↑/↓ fields · Ctrl-U clear · Enter next/save · Esc cancel" in
  let notes = (match t.mode with
    | Copy ->
        say "같은 계정과 API 모델을 쓰며 설정만 분리됩니다. 저장한 변형을 레인에 추가해 사용하세요."
          "Same account and API model; independent settings. Add the saved variant to a Lane to use it."
    | Edit ->
        say "컨텍스트·출력은 이 계정에만 적용됩니다. 추론 강도·Temperature는 이 모델을 공유하는 모든 계정에 적용되므로 분리하려면 복제를 사용하세요."
          "Context/output apply to this account. Effort/temperature affect every account sharing this model; use Copy for independent settings.") in
  let content =
    plain (wrap heading)
    @ List.concat (List.mapi (fun i row ->
        let selected = i = t.selected in
        List.map (fun line -> selected, line) (wrap row)) field_rows)
    @ plain (wrap notes) in
  (* Keep navigation visible even when a server error spans many rows. The
     field window, error prefix and key hint share one bounded height. *)
  let height = max 0 height in
  let hints = wrap hint in
  let hints = if List.length hints < height then hints
    else List.take height (wrap
      (if input_locked then say "Esc:뒤로 · 입력 유지" "Esc back · input retained"
       else say "Esc:취소 · Enter:다음/저장" "Esc cancel · Enter next/save")) in
  let available = max 0 (height - List.length hints) in
  let errors = match t.error with None -> [] | Some error -> wrap ((say "오류: " "Error: ") ^ error) in
  let error_room = max 0 (available - (if available > 1 then 1 else 0)) in
  let errors = if List.length errors <= error_room then errors
    else if error_room = 0 then []
    else if error_room = 1 then List.take 1 errors
    else List.take (error_room - 1) errors
      @ [Masc_tui_message_layout.fit_middle (max 1 width)
           (say "… 오류 계속 · 수정하거나 Esc" "… error continues; edit or Esc")] in
  let room = max 0 (available - List.length errors) in
  let selected_line = List.length (wrap heading) + List.fold_left (fun n row -> n + List.length (wrap row)) 0 (List.take t.selected field_rows) in
  let first = max 0 (selected_line - room + 1) in
  List.take room (List.drop first content) @ plain errors @ plain hints

let rows ?ko ?input_locked ~width ~height t =
  List.map snd (rows_with_selection ?ko ?input_locked ~width ~height t)

let path parts = String.concat "." (List.map Edit_text.render_key parts)
let errors errors = String.concat "; " (List.map (fun (e:Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors)
open Result.Syntax
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
        let array = match header with
          | Some (Edit_text.Table_array _) -> true
          | Some (Edit_text.Table _) | None -> false in
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
      when context <> Option.map snd t.source.context ->
      let requested = match context, provider.max_context with
        | Some value, _ | None, Some value -> Some value
        | None, None -> source.max_context in
      set_int draft "num-ctx" requested
    | Some { api_format = (Runtime_schema.Messages_api | Runtime_schema.Chat_completions_api | Runtime_schema.Gemini_api | Runtime_schema.Vertex_gemini_api | Runtime_schema.Codex_app_server_runtime | Runtime_schema.Antigravity_cli_runtime | Runtime_schema.Claude_code_runtime | Runtime_schema.Acp_runtime);_}
    | None | Some {api_format=Ollama_api; _ } -> draft in
  let draft = if effort = Option.value ~default:"" t.source.reasoning_effort then draft else
    let draft = if effort = "" then draft else
      Edit_text.edit_table_scalar draft ~path:model_path ~key:"reasoning-uncontrolled" ~value:None in
    Edit_text.edit_table_scalar draft ~path:model_path ~key:"reasoning-effort" ~value:(if effort = "" then None else Some effort) in
  let draft = if value t Temperature = Option.value ~default:"" t.source.temperature then draft else match temperature with
    | Some value -> Edit_text.edit_table_float draft ~path:model_path ~key:"temperature" ~value
    | None -> Edit_text.edit_table_scalar draft ~path:model_path ~key:"temperature" ~value:None in
  Runtime_toml.parse_string draft |> Result.map_error errors |> Result.map (fun _ -> draft)
