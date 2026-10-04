type row =
  { model : string
  ; provider : string
  ; api_name : string option
  ; reasoning_effort : string option
  ; temperature : string option
  ; max_tokens : int option
  }

let models_table = Runtime_toml_namespace.(key Models)

(* Section headers are [a.b] or [a."b with dots"]. The quoted form exists
   because model names carry dots (glm-5.2), which would otherwise split the
   path. Strip the quotes here so the two tables key on the same string. *)
let unquote s =
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then String.sub s 1 (n - 2) else s

let section_of_line line =
  let trimmed = String.trim line in
  let n = String.length trimmed in
  if n < 2 || trimmed.[0] <> '[' || trimmed.[n - 1] <> ']'
  then None
  else (
    let inner = String.sub trimmed 1 (n - 2) in
    (* A double-bracket [[x]] leaves a stray bracket after the strip. Those
       are array-of-table entries and never name a binding. *)
    if String.length inner > 0 && (inner.[0] = '[' || inner.[String.length inner - 1] = ']')
    then None
    else (
      match String.index_opt inner '.' with
      | None -> None
      | Some i ->
        let head = String.sub inner 0 i in
        let tail = String.sub inner (i + 1) (String.length inner - i - 1) in
        (* Only the first dot separates the table from the name: a quoted
           name may hold more. Reject a tail that opens a sub-table
           ([models.x.capabilities]) by checking for an unquoted dot. *)
        if (not (String.length tail > 0 && tail.[0] = '"')) && String.contains tail '.'
        then None
        else Some (head, unquote tail)))

let key_value line =
  match String.index_opt line '=' with
  | None -> None
  | Some i ->
    let k = String.trim (String.sub line 0 i) in
    let v = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
    if String.length k = 0 || String.length v = 0 then None else Some (k, unquote v)

let is_comment line =
  let t = String.trim line in
  String.length t > 0 && t.[0] = '#'

(* Two passes over the same lines rather than one pass with a pending state:
   [models.X] can appear after [ollama_cloud.X], and a single pass would have
   to buffer either way. *)
let collect lines ~table_is_models =
  let acc = Hashtbl.create 64 in
  let current = ref None in
  List.iter
    (fun line ->
      match section_of_line line with
      | Some (head, name) ->
        let matches =
          if table_is_models
          then String.equal head models_table
          else not (String.equal head models_table)
        in
        if matches
        then (
          current := Some (head, name);
          (* Register on the header, not on the first key. A section with no
             keys still exists -- [ollama_cloud.minimax-m3] shipped as a bare
             header -- and waiting for a key would drop its binding from the
             table entirely. *)
          if not (Hashtbl.mem acc name) then Hashtbl.replace acc name (head, []))
        else current := None
      | None ->
        if not (is_comment line)
        then (
          match !current, key_value line with
          | Some (_, name), Some (k, v) ->
            let head, fields = try Hashtbl.find acc name with Not_found -> ("", []) in
            Hashtbl.replace acc name (head, (k, v) :: fields)
          | _ -> ()))
    lines;
  acc

let int_of_value v = int_of_string_opt (String.trim v)

let parse lines =
  let models = collect lines ~table_is_models:true in
  let bindings = collect lines ~table_is_models:false in
  (* A [PROVIDER.NAME] section is a model binding only when [models.NAME]
     declares the model too. Sections like [providers.ollama] and
     [voice.tts] share the two-part shape and would otherwise land in the
     table. Pairing on the model table is structural, so a provider added
     later needs no edit here -- a hardcoded name list would. *)
  let rows =
    Hashtbl.fold
      (fun name (provider, fields) acc ->
        match Hashtbl.find_opt models name with
        | None -> acc
        | Some (_, model_fields) ->
          { model = name
          ; provider
          ; api_name = List.assoc_opt "api-name" model_fields
          ; reasoning_effort = List.assoc_opt "reasoning-effort" model_fields
          ; temperature = List.assoc_opt "temperature" model_fields
          ; max_tokens = Option.bind (List.assoc_opt "max-tokens" fields) int_of_value
          }
          :: acc)
      bindings
      []
  in
  List.sort
    (fun a b ->
      match String.compare a.provider b.provider with
      | 0 -> String.compare a.model b.model
      | c -> c)
    rows

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
  match r.api_name with
  | Some api when not (String.equal api r.model) -> r.model ^ " (" ^ api ^ ")"
  | Some _ | None -> r.model

(* The cells one complete row spends: every mandatory reading at its own
   measured width plus the gutters between. The header reserves fixed widths
   for the two knobs, so a reading longer than its reservation (a wide
   effort, an eleven-cell temperature) is what can push a row past the
   header's own arithmetic. *)
let row_cells ~provider_width r =
  provider_width + gutter + Masc_tui_message_layout.display_width (model_text r)
  + gutter + Masc_tui_message_layout.display_width (effort_text r.reasoning_effort)
  + gutter
  + Masc_tui_message_layout.display_width (value_or_absent r.temperature)
  + gutter + Masc_tui_message_layout.display_width (tokens_text r.max_tokens)

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
    header_cells ~provider_width ~model_width:(model_width_of rows) <= width
    && List.for_all (fun r -> row_cells ~provider_width r <= width) rows

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
  let fixed =
    provider_width + gutter + effort_width + gutter + temperature_width
    + gutter + tokens_width + gutter
  in
  let model_width = max 8 (width - fixed) in
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
