type row =
  { model : string
  ; provider : string
  ; api_name : string option
  ; reasoning_effort : string option
  ; temperature : string option
  ; context : (string * int) option
  ; model_context : int option
  ; max_tokens : int option
  }

let models_table = Runtime_toml_namespace.(key Models)

let parse lines =
  let text = String.concat "\n" lines in
  let ( let* ) = Result.bind in
  let* config = Runtime_toml.parse_string text
    |> Result.map_error (fun errors -> String.concat "; "
      (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors)) in
  let rows = List.filter_map (fun (binding : Runtime_schema.binding) ->
    match List.find_opt (fun (model : Runtime_schema.model_spec) ->
      String.equal model.id binding.model_id) config.models,
      Runtime_schema.provider_of_id config binding.provider_id with
    | Some model, Some provider ->
      let context = match binding.max_context, provider.max_context, model.max_context with
        | Some n, _, _ -> Some ("binding", n)
        | None, Some n, _ -> Some ("provider", n)
        | None, None, Some n -> Some ("model", n)
        | None, None, None -> None in
      Some { model = model.id; provider = provider.id;
        api_name = Some model.api_name;
        reasoning_effort = Option.map Llm_provider.Reasoning_effort.to_string model.reasoning_effort;
        temperature = Option.map (Printf.sprintf "%.15g") model.temperature;
        max_tokens = binding.max_tokens; context; model_context = model.max_context }
    | None, _ | _, None -> None) config.bindings in
  Ok (List.sort (fun a b -> match String.compare a.provider b.provider with
    | 0 -> String.compare a.model b.model | c -> c) rows)

(* ASCII, not an em dash: padding counts bytes, and a multi-byte dash makes
   every column after it hang one cell short of where the header sits. *)
let absent = "-"

let effort_text = function
  | Some e -> e
  | None -> absent

let tokens_text = function
  | Some n -> string_of_int n
  | None -> absent

let value_or_absent = Option.value ~default:absent

let is_bare_key_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false

let toml_key name =
  if String.length name > 0 && String.for_all is_bare_key_char name
  then name
  else (
    let escaped = Buffer.create (String.length name + 4) in
    String.iter
      (function
        | '\\' -> Buffer.add_string escaped "\\\\"
        | '"' -> Buffer.add_string escaped "\\\""
        | '\n' -> Buffer.add_string escaped "\\n"
        | '\r' -> Buffer.add_string escaped "\\r"
        | '\t' -> Buffer.add_string escaped "\\t"
        | c -> Buffer.add_char escaped c)
      name;
    Printf.sprintf "\"%s\"" (Buffer.contents escaped))

let section head model = Printf.sprintf "[%s.%s]" head (toml_key model)

let detail_lines row =
  let api_name, api_note =
    match row.api_name with
    | Some api when not (String.equal api row.model) -> api, " (api-name override)"
    | Some api -> api, " (same as binding)"
    | None -> row.model, " (default; api-name key absent)"
  in
  [ Printf.sprintf "Binding: provider=%s  model=%s" row.provider row.model
  ; Printf.sprintf "API model: %s%s" api_name api_note
  ; Printf.sprintf
      "%s  reasoning-effort=%s  temperature=%s"
      (section models_table row.model)
      (value_or_absent row.reasoning_effort)
      (value_or_absent row.temperature)
  ; Printf.sprintf
      "%s  max-tokens=%s"
      (section row.provider row.model)
      (tokens_text row.max_tokens)
  ; (match row.context with None -> "Context: undeclared; Runtime shows the resolved catalog value"
     | Some (source, n) -> Printf.sprintf "Context: %d tokens (%s); model specification: %s" n source (tokens_text row.model_context))
  ; "- means that key is absent; add or edit it in the section shown above."
  ]

let pad s n =
  (* Cells, not bytes. Model and provider names come from runtime.toml, so
     a name outside ASCII is a configuration away, and a byte count would
     pad it short -- every column after it shifts on that row alone. *)
  let cells = Masc_tui_message_layout.display_width s in
  if cells >= n then s else s ^ String.make (n - cells) ' '

(* Clip on the model column only. A clipped "1638" for 16384 is a different
   number and reads as fact; a clipped name still points at the right row. *)
let clip s n =
  if Masc_tui_message_layout.display_width s <= n then s
  else
    (* [String.sub] here cut at a byte, which splits a multi-byte scalar and
       puts its pieces on screen. [fit_width] cuts at a cell and fills the
       column, with the same trailing […]. *)
    Masc_tui_message_layout.fit_width s n

let effort_width = 8
let temperature_width = 11
let tokens_width = 11
let gutter = 2

let provider_width_of rows =
  List.fold_left
    (fun acc r -> max acc (Masc_tui_message_layout.display_width r.provider))
    (Masc_tui_message_layout.display_width "provider")
    rows

(* The model column shows the binding name, and the api-name override when
   there is one: they are what identifies a row to a reader who wants to fix
   it in runtime.toml. Measuring from the same text the row draws keeps the
   fit decision and the drawing honest with each other. *)
let model_text r =
  let name = match r.api_name with
  | Some api when not (String.equal api r.model) -> r.model ^ " (" ^ api ^ ")"
  | Some _ | None -> r.model in
  name ^ (match r.context with None -> "" | Some (_, n) -> Printf.sprintf " [%d ctx]" n)

(* The cells one complete row spends: every mandatory reading at its own
   measured width plus the gutters between. The header reserves fixed widths
   for the two knobs, so a reading longer than its reservation (a wide
   effort, an eleven-cell temperature) is what can push a row past the
   header's own arithmetic. *)
let row_cells ~provider_width ~model_width r =
  (* [pad] fills a short knob to its reservation and never clips a long one,
     so each cell is the wider of the two. *)
  provider_width + gutter + model_width + gutter
  + max effort_width
      (Masc_tui_message_layout.display_width (effort_text r.reasoning_effort))
  + gutter
  + max temperature_width
      (Masc_tui_message_layout.display_width (value_or_absent r.temperature))
  + gutter + Masc_tui_message_layout.display_width (tokens_text r.max_tokens)

(* What [render] reserves before the model column, and the model column it
   then draws. [fits] measures this same allocation: measuring natural widths
   accepted tables that [render] clipped (#41026 review). *)
let fixed_cells ~provider_width =
  provider_width + gutter + effort_width + gutter + temperature_width
  + gutter + tokens_width + gutter

let model_column ~width ~provider_width =
  max 8 (width - fixed_cells ~provider_width)

let header_cells ~provider_width ~model_width =
  provider_width + gutter + model_width + gutter + effort_width + gutter
  + temperature_width + gutter + String.length "max-tokens"

let model_width_of rows =
  max 8
    (List.fold_left
       (fun acc r -> max acc (Masc_tui_message_layout.display_width (model_text r)))
       (Masc_tui_message_layout.display_width "model") rows)

let fits ~width rows =
  match rows with
  | [] -> true
  | _ ->
    let provider_width = provider_width_of rows in
    let model_width = model_column ~width ~provider_width in
    model_width_of rows <= model_width
    && header_cells ~provider_width ~model_width <= width
    && List.for_all
         (fun r -> row_cells ~provider_width ~model_width r <= width)
         rows

(* One binding as named, wrapped lines. A label wider than the pane goes on
   its own line and wraps; a value keeps its complete characters because
   [wrap_words] splits at cell boundaries. No number is shortened into a
   different number on the way through. *)
let stacked_lines ~pane rows =
  let wrap text = Masc_tui_message_layout.wrap_words ~max_cells:pane text in
  let item r =
    wrap (Printf.sprintf "%s %s" r.provider (model_text r))
    @ wrap
        (Printf.sprintf
           "effort %s · temperature %s · max-tokens %s"
           (effort_text r.reasoning_effort)
           (value_or_absent r.temperature)
           (tokens_text r.max_tokens))
  in
  match rows with
  | [] -> [ "no model bindings in runtime.toml" ]
  | _ ->
    (* Items are separated by a blank line: on a pane this narrow the reader
       is scanning one binding at a time, and unseparated wrapped runs read
       as one record. *)
    List.concat_map (fun r -> item r @ [ "" ]) rows
    |> fun lines ->
    (match List.rev lines with
     | _ :: rest -> List.rev rest  (* drop the trailing separator *)
     | [] -> [])

(* Where each binding's item starts in the stacked document -- the line the
   pane marks when its cursor (a binding index) is on that row. *)
let stacked_item_starts ~pane rows =
  let wrap_len text =
    List.length (Masc_tui_message_layout.wrap_words ~max_cells:pane text)
  in
  let item_len r =
    wrap_len (Printf.sprintf "%s %s" r.provider (model_text r))
    + wrap_len
        (Printf.sprintf
           "effort %s · temperature %s · max-tokens %s"
           (effort_text r.reasoning_effort)
           (value_or_absent r.temperature)
           (tokens_text r.max_tokens))
  in
  let rec starts acc at = function
    | [] -> List.rev acc
    | r :: rest -> starts (at :: acc) (at + item_len r + 1) rest
  in
  starts [] 0 rows

let render ~width ?pane rows =
  let provider_width = provider_width_of rows in
  let model_width = model_column ~width ~provider_width in
  let header =
    pad "provider" provider_width
    ^ String.make gutter ' '
    ^ pad "model" model_width
    ^ String.make gutter ' '
    ^ pad "effort" effort_width
    ^ String.make gutter ' '
    ^ pad "temperature" temperature_width
    ^ String.make gutter ' '
    ^ "max-tokens"
  in
  let line r =
    pad r.provider provider_width
    ^ String.make gutter ' '
    ^ pad (clip (model_text r) model_width) model_width
    ^ String.make gutter ' '
    ^ pad (effort_text r.reasoning_effort) effort_width
    ^ String.make gutter ' '
    ^ pad (value_or_absent r.temperature) temperature_width
    ^ String.make gutter ' '
    ^ tokens_text r.max_tokens
  in
  match rows with
  | [] -> [ "no model bindings in runtime.toml" ]
  | _ ->
    (* The frame's cut is a last resort, not this table's layout policy. When
       the pane offers fewer cells than the complete mandatory readings need,
       draw one named, wrapped item per binding instead: every reading stays
       reachable, and no number is shortened into a different number. *)
    (match pane with
     | Some pane when not (fits ~width:pane rows) -> stacked_lines ~pane rows
     | _ -> header :: List.map line rows)

let find_runtime ~runtime_id rows =
  List.find_mapi (fun index (row : row) ->
    if String.equal (row.provider ^ "." ^ row.model) runtime_id
    then Some (index, row) else None) rows
