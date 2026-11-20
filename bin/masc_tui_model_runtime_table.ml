type row =
  { model : string
  ; provider : string
  ; api_name : string option
  ; reasoning_effort : string option
  ; temperature : string option
  ; context : (string * int) option
  ; model_context : int option
  ; max_tokens : int option
  ; same_login : string list
  ; login_group : int option
  ; account_label : string option
  }

let models_table = Runtime_toml_namespace.(key Models)

let of_projection ?(account_groups = []) (projection : Runtime_config_models.t) =
  let ids = List.concat account_groups in
  if List.exists (fun id -> not (List.mem id projection.provider_ids)) ids
     || List.exists (fun group -> group = []) account_groups
     || List.length ids <> List.length (List.sort_uniq String.compare ids)
  then Error "account groups do not identify disjoint providers in this source"
  else
  let same_login provider =
    match List.find_opt (List.mem provider) account_groups with
    | None -> []
    | Some ids -> List.filter (fun id -> not (String.equal id provider)) ids
        |> List.sort_uniq String.compare in
  let login_name provider = List.fold_left min provider (same_login provider) in
  let shared_logins = List.filter_map (fun provider ->
    match same_login provider with
    | [] -> None | _ :: _ -> Some (login_name provider)) projection.provider_ids
    |> List.sort_uniq String.compare in
  let login_group provider =
    List.find_index (String.equal (login_name provider)) shared_logins
    |> Option.map (fun index -> index + 1) in
  let context_source = function
    | Runtime_config_models.Binding -> "binding"
    | Provider -> "provider"
    | Model -> "model" in
  let rows = List.map (fun (binding : Runtime_config_models.binding) ->
    {model=binding.model; provider=binding.provider; api_name=Some binding.api_name;
     reasoning_effort=Option.map Llm_provider.Reasoning_effort.to_string binding.reasoning_effort;
     temperature=Option.map (Printf.sprintf "%.15g") binding.temperature;
     context=Option.map (fun (source,n) -> context_source source,n) binding.context;
     model_context=binding.model_context; max_tokens=binding.max_tokens;
     same_login=same_login binding.provider; login_group=login_group binding.provider;
     account_label=None}) projection.bindings in
  let login_of row = List.fold_left min row.provider row.same_login in
  Ok (List.sort (fun a b -> match String.compare (login_of a) (login_of b) with
    | 0 -> (match String.compare a.provider b.provider with
      | 0 -> String.compare a.model b.model | c -> c)
    | c -> c) rows)

let parse ?(account_groups = []) lines =
  let open Result.Syntax in
  let* config = Runtime_toml.parse_string (String.concat "\n" lines)
    |> Result.map_error (fun errors -> String.concat "; "
      (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors)) in
  let* projection = Runtime_config_models.of_config config in
  of_projection ~account_groups projection

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

let detail_lines ?(ko = false) ?account_email ?keepers row =
  let api_name, api_note =
    match row.api_name with
    | Some api when not (String.equal api row.model) ->
        api, if ko then " (api-name 재정의)" else " (api-name override)"
    | Some api ->
        api, if ko then " (바인딩과 동일)" else " (same as binding)"
    | None ->
        row.model, if ko then " (기본값 · api-name 미지정)" else " (default; api-name key absent)"
  in
  let account =
    (match account_email with
     | Some email ->
         [ Printf.sprintf (if ko then "계정: %s" else "Account: %s") email ]
     | None -> [])
    @ (match row.same_login with
       | [] -> []
       | others ->
         [ Printf.sprintf
             (if ko then "같은 로그인 공유: %s (공유 계정 홈)"
              else "Same login as %s (shared account-home)")
             (String.concat ", " others) ])
    @ (match keepers with
       | None -> []
       | Some [] ->
           [ if ko then "직접 배정된 키퍼(레인 제외): 없음"
             else "Keepers assigned directly (lanes not counted): none" ]
       | Some names ->
         [ Printf.sprintf
             (if ko then "직접 배정된 키퍼(레인 제외): %d명 - %s"
              else "Keepers assigned directly (lanes not counted): %d - %s")
             (List.length names) (String.concat ", " names) ])
  in
  [ Printf.sprintf
      (if ko then "바인딩: provider=%s  model=%s" else "Binding: provider=%s  model=%s")
      row.provider row.model ]
  @ account
  @ [ Printf.sprintf (if ko then "API 모델: %s%s" else "API model: %s%s") api_name api_note
    ; Printf.sprintf
        "%s  reasoning-effort=%s  temperature=%s"
        (section models_table row.model)
        (value_or_absent row.reasoning_effort)
        (value_or_absent row.temperature)
    ; Printf.sprintf
        "%s  max-tokens=%s"
        (section row.provider row.model)
        (tokens_text row.max_tokens)
    ; (match row.context with
       | None ->
           if ko then "컨텍스트: 미선언 · 런타임 화면에서 카탈로그 해석값 표시"
           else "Context: undeclared; Runtime shows the resolved catalog value"
       | Some (source, n) ->
           let source_label =
             if not ko then source
             else
               match source with
               | "binding" -> "바인딩"
               | "provider" -> "제공자"
               | "model" -> "모델"
               | other -> other
           in
           Printf.sprintf
             (if ko then "컨텍스트: %s 토큰 (%s) · 모델 사양: %s"
              else "Context: %s tokens (%s); model specification: %s")
             (Masc_tui_value.Count.grouped n) source_label (tokens_text row.model_context))
    ; (if ko then "- 는 해당 키가 설정되지 않았음을 뜻합니다. 위 섹션에서 추가하거나 수정할 수 있습니다."
       else "- means that key is absent; add or edit it in the section shown above.")
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

(* The provider column names the account beside the id: the label the pane
   read for the login, or [#n] when the id shares its login with others and
   no label was read. Every width and every drawn row measures this text. *)
let provider_text r =
  match r.account_label, r.login_group with
  | Some label, _ -> r.provider ^ " " ^ label
  | None, Some group -> Printf.sprintf "%s #%d" r.provider group
  | None, None -> r.provider

let account_label_cells = 18

let account_label_of_email email =
  let local = match String.index_opt email '@' with
    | Some at when at > 0 -> String.sub email 0 at
    | Some _ | None -> email in
  if Masc_tui_message_layout.display_width local <= account_label_cells then local
  else Masc_tui_message_layout.fit_width local account_label_cells

let keepers_on_login ~rows ~assignments row =
  let providers = row.provider :: row.same_login in
  let runtime_ids = List.filter_map (fun candidate ->
    if List.mem candidate.provider providers
    then Some (candidate.provider ^ "." ^ candidate.model) else None) rows in
  List.filter_map (fun (keeper, runtime_id) ->
    if List.mem runtime_id runtime_ids
    then Some keeper else None) assignments
  |> List.sort_uniq String.compare

module Model_names = Map.Make (String)

(* A binding name can exist on several accounts. Keep the exact owner on
   every such row; unique names use the selected account scope once. *)
let row_qualifier rows =
  let counts = List.fold_left (fun counts row ->
    Model_names.update row.model (function None -> Some 1 | Some n -> Some (n + 1)) counts)
    Model_names.empty rows in
  fun row ->
    match Model_names.find_opt row.model counts with
    | Some n when n > 1 -> Some (provider_text row)
    | Some _ | None -> None

let provider_header ~ko = if ko then "제공자" else "provider"
let model_header ~ko = if ko then "모델" else "model"
let effort_header ~ko = if ko then "추론" else "effort"
let temperature_header ~ko = if ko then "온도" else "temperature"
let max_tokens_header ~ko = if ko then "최대 토큰" else "max-tokens"

let provider_width_of ~ko ~qualifier rows =
  let width = List.fold_left (fun width row ->
    match qualifier row with
    | None -> width
    | Some owner -> max width (Masc_tui_message_layout.display_width owner)) 0 rows in
  if width = 0 then 0
  else max width (Masc_tui_message_layout.display_width (provider_header ~ko))

(* The exact binding name is the selection identity. The full API-name
   alias remains in the explicit detail reading rather than repeating beside
   every model. Context here is declared, not resolved catalogue capacity. *)
let model_text r =
  r.model ^ (match r.context with None -> "" | Some (_, n) -> Printf.sprintf " [%d ctx]" n)

(* The cells one complete row spends: every mandatory reading at its own
   measured width plus the gutters between. The header reserves fixed widths
   for the two knobs, so a reading longer than its reservation (a wide
   effort, an eleven-cell temperature) is what can push a row past the
   header's own arithmetic. *)
let row_cells ~provider_width ~model_width r =
  (* [pad] fills a short knob to its reservation and never clips a long one,
     so each cell is the wider of the two. *)
  model_width + gutter
  + max effort_width
      (Masc_tui_message_layout.display_width (effort_text r.reasoning_effort))
  + gutter
  + max temperature_width
      (Masc_tui_message_layout.display_width (value_or_absent r.temperature))
  + gutter
  + (let width = Masc_tui_message_layout.display_width (tokens_text r.max_tokens) in
     if provider_width = 0 then width else max tokens_width width)
  + (if provider_width = 0 then 0 else gutter + provider_width)

(* What [render] reserves outside the model column, and the model column it
   then draws. [fits] measures this same allocation: measuring natural widths
   accepted tables that [render] clipped (#41026 review). *)
let fixed_cells ~provider_width =
  gutter + effort_width + gutter + temperature_width + gutter + tokens_width
  + (if provider_width = 0 then 0 else gutter + provider_width)

let model_column ~width ~provider_width =
  max 8 (width - fixed_cells ~provider_width)

let header_cells ~ko ~provider_width ~model_width =
  model_width + gutter + effort_width + gutter + temperature_width + gutter
  + (if provider_width = 0 then
       Masc_tui_message_layout.display_width (max_tokens_header ~ko)
     else tokens_width + gutter + provider_width)

let model_width_of ~ko rows =
  max 8
    (List.fold_left
       (fun acc r -> max acc (Masc_tui_message_layout.display_width (model_text r)))
       (Masc_tui_message_layout.display_width (model_header ~ko)) rows)

let fits_rows ~ko ~width ~qualifier rows =
  match rows with
  | [] -> true
  | _ ->
    let provider_width = provider_width_of ~ko ~qualifier rows in
    let model_width = model_column ~width ~provider_width in
    model_width_of ~ko rows <= model_width
    && header_cells ~ko ~provider_width ~model_width <= width
    && List.for_all
         (fun r -> row_cells ~provider_width ~model_width r <= width)
         rows

let fits ?(ko = false) ~width rows =
  fits_rows ~ko ~width ~qualifier:(row_qualifier rows) rows

(* One binding as named, wrapped lines. A label wider than the pane goes on
   its own line and wraps; a value keeps its complete characters because
   [wrap_words] splits at cell boundaries. No number is shortened into a
   different number on the way through. *)
let stacked_items ~ko ~pane rows =
  let wrap text = Masc_tui_message_layout.wrap_words ~max_cells:pane text in
  let qualifier = row_qualifier rows in
  let item r =
    wrap (model_text r)
    @ wrap
        (Printf.sprintf
           (if ko then "추론 %s · 온도 %s · 최대 토큰 %s"
            else "effort %s · temperature %s · max-tokens %s")
           (effort_text r.reasoning_effort)
           (value_or_absent r.temperature)
           (tokens_text r.max_tokens))
    @ (match qualifier r with None -> [] | Some owner -> wrap owner)
  in
  List.map item rows

let stacked_lines ~ko ~pane rows =
  match rows with
  | [] ->
      [ if ko then "runtime.toml에 모델 바인딩이 없습니다"
        else "no model bindings in runtime.toml" ]
  | _ ->
    (* Items are separated by a blank line: on a pane this narrow the reader
       is scanning one binding at a time, and unseparated wrapped runs read
       as one record. *)
    List.concat_map (fun item -> item @ [ "" ]) (stacked_items ~ko ~pane rows)
    |> fun lines ->
    (match List.rev lines with
     | _ :: rest -> List.rev rest  (* drop the trailing separator *)
     | [] -> [])

(* Where each binding's item starts in the stacked document -- the line the
   pane marks when its cursor (a binding index) is on that row. *)
let stacked_item_starts ?(ko = false) ~pane rows =
  let rec starts acc at = function
    | [] -> List.rev acc
    | item :: rest -> starts (at :: acc) (at + List.length item + 1) rest
  in
  starts [] 0 (stacked_items ~ko ~pane rows)

let selected_lines ~table ~starts ~total cursor =
  if table then (cursor + 1, cursor + 1)
  else
    let start = Option.value ~default:0 (List.nth_opt starts cursor) in
    let stop =
      match List.nth_opt starts (cursor + 1) with
      | Some next -> next - 2
      | None -> total - 1
    in
    (start, stop)

(* The lines the window keeps on screen for binding [cursor]: its own, and
   for the first table row the column names above it as well, so Home shows
   them -- while both fit. A pane one line tall keeps the binding. *)
let binding_span ~table ~starts ~total ~height cursor =
  let start, stop = selected_lines ~table ~starts ~total cursor in
  if table && cursor = 0 && stop < height then (0, stop) else (start, stop)

let window ~table ~starts ~total ~height ~cursor scroll =
  let start, stop = binding_span ~table ~starts ~total ~height cursor in
  let max_scroll = Int.max 0 (total - height) in
  let scroll = Int.max 0 (Int.min scroll max_scroll) in
  Int.min max_scroll (Masc_tui_scroll.ensure_span_visible ~start ~stop ~height scroll)

let page_bindings ~table ~starts ~total ~height =
  let count = if table then Int.max 0 (total - 1) else List.length starts in
  let spans = Array.init count (binding_span ~table ~starts ~total ~height) in
  (* How many bindings from [first] on fit the pane together; [None] when
     the list ends before the pane does, which limits no page. *)
  let fit_from first =
    let rec grow taken =
      if first + taken >= count then None
      else if snd spans.(first + taken) - fst spans.(first) + 1 > height then Some taken
      else grow (taken + 1)
    in
    grow 0
  in
  let fewest =
    List.fold_left
      (fun fewest first ->
        match fit_from first with Some taken -> Int.min fewest taken | None -> fewest)
      count (List.init count Fun.id)
  in
  Int.max 1 fewest

let reads_selected ~table ~starts ~total ~height cursor =
  let start, stop = selected_lines ~table ~starts ~total cursor in
  (not table) && stop - start + 1 > height

let wrap_style code text =
  if String.equal code "" || String.equal text "" then text
  else code ^ text ^ Masc_tui_theme.Sgr.reset

let render ?(ko = false) ~width ?pane rows =
  let qualifier = row_qualifier rows in
  let provider_width = provider_width_of ~ko ~qualifier rows in
  let model_width = model_column ~width ~provider_width in
  let recede =
    Masc_tui_theme.recede ~surface:Masc_tui_theme.Page
      (Masc_tui_terminal_palette.snapshot_palette
         (Masc_tui_terminal_palette.snapshot ()))
  in
  let dim_if_absent text padded =
    if String.equal text absent then wrap_style recede padded else padded
  in
  let owner text = if provider_width = 0 then ""
    else String.make gutter ' ' ^ pad text provider_width in
  let styled_owner text =
    if provider_width = 0 then ""
    else if String.equal text "" then String.make (gutter + provider_width) ' '
    else String.make gutter ' ' ^ wrap_style recede (pad text provider_width)
  in
  let tokens text = if provider_width = 0 then text else pad text tokens_width in
  let styled_model r =
    let plain = model_text r in
    let plain_cells = Masc_tui_message_layout.display_width plain in
    if plain_cells > model_width then pad (clip plain model_width) model_width
    else
      let trailing = String.make (model_width - plain_cells) ' ' in
      match r.context with
      | None -> r.model ^ trailing
      | Some (_, n) ->
          r.model ^ wrap_style recede (Printf.sprintf " [%d ctx]" n) ^ trailing
  in
  let header =
    pad (model_header ~ko) model_width
    ^ String.make gutter ' '
    ^ pad (effort_header ~ko) effort_width
    ^ String.make gutter ' '
    ^ pad (temperature_header ~ko) temperature_width
    ^ String.make gutter ' '
    ^ tokens (max_tokens_header ~ko) ^ owner (provider_header ~ko)
  in
  let line r =
    let eff = effort_text r.reasoning_effort in
    let temp = value_or_absent r.temperature in
    let tok = tokens_text r.max_tokens in
    styled_model r
    ^ String.make gutter ' '
    ^ dim_if_absent eff (pad eff effort_width)
    ^ String.make gutter ' '
    ^ dim_if_absent temp (pad temp temperature_width)
    ^ String.make gutter ' '
    ^ dim_if_absent tok (tokens tok)
    ^ styled_owner (Option.value ~default:"" (qualifier r))
  in
  match rows with
  | [] ->
      [ if ko then "runtime.toml에 모델 바인딩이 없습니다"
        else "no model bindings in runtime.toml" ]
  | _ ->
    (* The frame's cut is a last resort, not this table's layout policy. When
       the pane offers fewer cells than the complete mandatory readings need,
       draw one named, wrapped item per binding instead: every reading stays
       reachable, and no number is shortened into a different number. *)
    (match pane with
     | Some pane when not (fits_rows ~ko ~width:pane ~qualifier rows) ->
         stacked_lines ~ko ~pane rows
     | _ -> header :: List.map line rows)

let find_runtime ~runtime_id rows =
  List.find_mapi (fun index (row : row) ->
    if String.equal (row.provider ^ "." ^ row.model) runtime_id
    then Some (index, row) else None) rows
