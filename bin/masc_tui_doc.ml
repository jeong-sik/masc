module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme
module Layout = Masc_tui_message_layout
module Text_block = Masc_tui_text_block
module Card = Masc_tui_card

type kv_field =
  { label : string
  ; value : string
  ; value_tone : string
  }

let kv ?(tone = "") label value = { label; value; value_tone = tone }

let sanitize = Masc.Tui_terminal_text.sanitize_terminal_text
let cells text = Layout.display_width (Masc_tui_theme.strip_sgr text)

let paint style text =
  if String.equal style "" || String.equal text "" then text
  else style ^ text ^ Ansi.reset

let clamp_plain ~max_cells text =
  if max_cells <= 0 then ""
  else if Layout.display_width text <= max_cells then text
  else Layout.truncate_end max_cells text

let sanitize_footer_keys keys =
  List.map
    (fun (fk : Card.inline_key) ->
      { Card.key = sanitize fk.Card.key; label = sanitize fk.Card.label })
    keys

let repeat_glyph glyph n =
  if n <= 0 then ""
  else
    let buf = Buffer.create (String.length glyph * n) in
    for _ = 1 to n do
      Buffer.add_string buf glyph
    done;
    Buffer.contents buf

let section_rule ~width ?(indent = 0) ?badge ?badge_tone title =
  if width <= 0 then ""
  else
    let indent = max 0 (min indent (max 0 (width - 1))) in
    let room = width - indent in
    let margin = String.make indent ' ' in
    let rule_sgr = Theme.border_muted () in
    let h = Masc_tui_theme.Box.h in
    let clean_title = sanitize title in
    let clean_badge =
      match badge with
      | None -> ""
      | Some raw -> String.trim (sanitize raw)
    in
    let heading_style = Ansi.bold ^ Theme.section_heading () in
    if room <= 4 then
      margin ^ paint heading_style (clamp_plain ~max_cells:room clean_title)
    else
      let lead_cells = min 2 (max 1 (room / 8)) in
      let lead = repeat_glyph h lead_cells ^ " " in
      let lead_w = lead_cells + 1 in
      let badge_part, badge_cells =
        if String.equal clean_badge "" then ("", 0)
        else
          let badge_cap = max 0 (room / 3) in
          if badge_cap < 3 then ("", 0)
          else
            let fitted_badge = clamp_plain ~max_cells:badge_cap clean_badge in
            let w = cells fitted_badge in
            let raw_badge_cells = 1 + w in
            if w = 0 || room - lead_w - raw_badge_cells < 2 then ("", 0)
            else
              let tone = Option.value badge_tone ~default:(Theme.recede ()) in
              (" " ^ paint tone fitted_badge, raw_badge_cells)
      in
      let title_budget = max 1 (room - lead_w - badge_cells) in
      let fitted_title = clamp_plain ~max_cells:title_budget clean_title in
      let title_w = cells fitted_title in
      let used = lead_w + title_w + badge_cells in
      let tail_cells = max 0 (room - used) in
      let tail =
        if tail_cells >= 2 then " " ^ repeat_glyph h (tail_cells - 1)
        else if tail_cells = 1 && badge_cells > 0 then " "
        else ""
      in
      margin ^ paint rule_sgr lead ^ paint heading_style fitted_title
      ^ paint rule_sgr tail ^ badge_part

let kv_rows ~width ?(indent = 2) ?label_style ?(max_label_cells = 18) fields =
  if width <= 0 || fields = [] then []
  else
    let indent = max 0 (min indent (max 0 (width - 1))) in
    let content_w = max 1 (width - indent) in
    let margin = String.make indent ' ' in
    let lbl_style = Option.value label_style ~default:(Theme.recede ()) in
    let clean_fields =
      List.map (fun field -> { field with label = sanitize field.label }) fields
    in
    let widest_label =
      List.fold_left
        (fun acc field ->
          if String.equal field.label "" then acc
          else max acc (cells field.label))
        0 clean_fields
    in
    let cap_label = min max_label_cells (max 4 (content_w / 3)) in
    let col_w = min widest_label cap_label in
    let gutter = "  " in
    let gutter_w = 2 in
    let two_col = col_w > 0 && col_w + gutter_w + 12 <= content_w in
    let wrap_clamped max_w value =
      let rows =
        match Text_block.rows ~max_cells:(max 1 max_w) value with
        | [] -> [ "" ]
        | rows -> rows
      in
      List.map (clamp_plain ~max_cells:max_w) rows
    in
    if two_col then
      let val_w = content_w - col_w - gutter_w in
      let cont_prefix = margin ^ String.make (col_w + gutter_w) ' ' in
      List.concat_map
        (fun field ->
          if String.equal field.label "" then
            wrap_clamped content_w field.value
            |> List.map (fun row -> margin ^ paint field.value_tone row)
          else
            let fitted_label = clamp_plain ~max_cells:col_w field.label in
            let pad = String.make (max 0 (col_w - cells fitted_label)) ' ' in
            let first_prefix =
              margin ^ paint lbl_style fitted_label ^ pad ^ gutter
            in
            wrap_clamped val_w field.value
            |> List.mapi (fun idx row ->
                   let prefix = if idx = 0 then first_prefix else cont_prefix in
                   prefix ^ paint field.value_tone row))
        clean_fields
    else
      let val_indent_cells = if content_w >= 8 then 2 else 0 in
      let val_margin = margin ^ String.make val_indent_cells ' ' in
      let val_w = max 1 (content_w - val_indent_cells) in
      List.concat_map
        (fun field ->
          let lbl_row =
            if String.equal field.label "" then []
            else [ margin ^ paint lbl_style (clamp_plain ~max_cells:content_w field.label) ]
          in
          let val_prefix = if String.equal field.label "" then margin else val_margin in
          let max_val_w =
            if String.equal field.label "" then content_w else val_w
          in
          let val_rows =
            wrap_clamped max_val_w field.value
            |> List.map (fun row -> val_prefix ^ paint field.value_tone row)
          in
          lbl_row @ val_rows)
        clean_fields

(* Matches inline "(1) " .. "(99) " preceded by ASCII space/tab so function
   calls or reference tags like "#53292(axis C)" are never split mid-token. *)
let numbered_paren_marker_at s idx =
  let len = String.length s in
  if idx + 3 >= len || idx <= 0 then false
  else
    let prev = s.[idx - 1] in
    if prev <> ' ' && prev <> '\t' then false
    else if s.[idx] <> '(' then false
    else
      let is_digit c = c >= '0' && c <= '9' in
      if is_digit s.[idx + 1] && idx + 3 < len && s.[idx + 2] = ')' && s.[idx + 3] = ' ' then
        true
      else if
        idx + 4 < len && is_digit s.[idx + 1] && is_digit s.[idx + 2]
        && s.[idx + 3] = ')' && s.[idx + 4] = ' '
      then true
      else false

let has_non_space s ~from ~until =
  let rec loop i =
    if i >= until then false
    else if s.[i] <> ' ' && s.[i] <> '\t' then true
    else loop (i + 1)
  in
  loop from

let trim_end_spaces s =
  let len = ref (String.length s) in
  while !len > 0 && (s.[!len - 1] = ' ' || s.[!len - 1] = '\t') do
    decr len
  done;
  if !len = String.length s then s else String.sub s 0 !len

let split_inline_numbered s =
  let len = String.length s in
  let acc = ref [] in
  let start = ref 0 in
  for idx = 1 to len - 1 do
    if numbered_paren_marker_at s idx && has_non_space s ~from:!start ~until:idx then begin
      let piece = trim_end_spaces (String.sub s !start (idx - !start)) in
      if not (String.equal piece "") then acc := piece :: !acc;
      start := idx
    end
  done;
  let tail = String.sub s !start (len - !start) in
  if List.length !acc = 0 then [ s ]
  else List.rev (if String.for_all (fun c -> c = ' ' || c = '\t') tail then !acc else tail :: !acc)

let split_numbered_paragraphs text =
  Text_block.lines text |> List.concat_map split_inline_numbered

(* Only ASCII spaces represent empty lines here; tabs/CR/other controls must
   still pass through [Text_block.rows] -> [sanitize_terminal_text]. *)
let is_blank_space_line s = String.for_all (fun c -> c = ' ') s

let prose_block ~width ?(indent = 2) ?guide_style ?(break_numbered = false)
    ?(tone = "") text =
  if width <= 0 then []
  else
    let indent = max 0 (min indent (max 0 (width - 1))) in
    let content_w = max 1 (width - indent) in
    let guide_w = if content_w >= 4 then 2 else 0 in
    let text_w = max 1 (content_w - guide_w) in
    let margin = String.make indent ' ' in
    let g_style = Option.value guide_style ~default:(Theme.border_muted ()) in
    let guide =
      if guide_w = 0 then ""
      else paint g_style (Masc_tui_theme.Box.v ^ " ")
    in
    let raw_paragraphs =
      if break_numbered then split_numbered_paragraphs text
      else Text_block.lines text
    in
    let paragraphs =
      let drop_leading xs =
        let rec loop = function
          | p :: rest when is_blank_space_line p -> loop rest
          | rest -> rest
        in
        loop xs
      in
      raw_paragraphs |> drop_leading |> List.rev |> drop_leading |> List.rev
    in
    let multiple_numbered = break_numbered && List.length paragraphs > 1 in
    let rec render_loop prev_nonblank acc = function
      | [] -> List.rev acc
      | para :: rest ->
          if is_blank_space_line para then
            let row = margin ^ guide in
            render_loop false (row :: acc) rest
          else
            let acc =
              if multiple_numbered && prev_nonblank then
                let sep =
                  margin ^ if guide_w = 0 then "" else paint g_style Masc_tui_theme.Box.v
                in
                sep :: acc
              else acc
            in
            let wrapped =
              match Text_block.rows ~max_cells:text_w para with
              | [] -> [ "" ]
              | rows -> rows
            in
            let acc =
              List.fold_left
                (fun acc row ->
                  let fitted = clamp_plain ~max_cells:text_w row in
                  (margin ^ guide ^ paint tone fitted) :: acc)
                acc wrapped
            in
            render_loop true acc rest
    in
    render_loop false [] paragraphs

let card_style () =
  { Card.border = Theme.border_muted ()
  ; focused_border = Theme.border_focus ()
  ; title_style = Ansi.bold
  ; reset = Ansi.reset
  }

let panel_border_accent role =
  match role with
  | Masc_tui_theme.Panel_neutral -> None
  | Panel_fleet | Panel_usage | Panel_memory | Panel_attention ->
      let accent = Theme.panel_border role in
      if String.equal accent "" then None else Some accent

let action_callout_card ~ko ~width ~role ~title ~status ~next_step
    ~summary_clauses ~footer_keys =
  if width <= 0 then []
  else if width < Card.min_width then
    let rows =
      Text_block.rows ~max_cells:width next_step
      |> List.map (fun row -> paint Ansi.bold (clamp_plain ~max_cells:width row))
    in
    rows
  else
    let inner = Card.content_cells ~width in
    let next_rows =
      if is_blank_space_line next_step then []
      else
        Text_block.rows ~max_cells:(max 1 inner) next_step
        |> List.map (fun row -> paint Ansi.bold (clamp_plain ~max_cells:inner row))
    in
    let clause_text =
      summary_clauses
      |> List.filter_map (fun clause ->
             let clean = String.trim (sanitize clause) in
             if String.equal clean "" then None else Some clean)
      |> String.concat " · "
    in
    let clause_rows =
      if String.equal clause_text "" then []
      else
        Layout.wrap_words ~max_cells:(max 1 inner) clause_text
        |> List.map (fun row ->
               paint (Theme.recede ()) (clamp_plain ~max_cells:inner row))
    in
    let body_rows =
      let combined = next_rows @ clause_rows in
      if combined = [] then [ "" ] else combined
    in
    let height = max Card.min_height (min 7 (2 + List.length body_rows)) in
    let clean_status =
      { status with Card.word = sanitize status.Card.word }
    in
    let edge =
      { Card.name = sanitize title
      ; key = None
      ; status = Some clean_status
      ; count = None
      ; focus = Card.Unfocused
      ; border_accent = panel_border_accent role
      ; footer_keys = sanitize_footer_keys footer_keys
      }
    in
    Card.render ~ko ~style:(card_style ()) ~width ~height
      { Card.edge; body = (fun ~cells:_ -> body_rows) }

let bottom_sheet ~ko ~width ~height ~role ~title ?status ?count ?scrollbar
    ~footer_keys ~body () =
  let clean_status =
    Option.map
      (fun (s : Card.status) -> { s with Card.word = sanitize s.Card.word })
      status
  in
  let edge =
    { Card.name = sanitize title
    ; key = None
    ; status = clean_status
    ; count
    ; focus = Card.Unfocused
    ; border_accent = panel_border_accent role
    ; footer_keys = sanitize_footer_keys footer_keys
    }
  in
  Card.render ?scrollbar ~ko ~style:(card_style ()) ~width ~height
    { Card.edge; body }

let hairline ~width ?(indent = 0) ?tone () =
  if width <= 0 then ""
  else
    let indent = max 0 (min indent (max 0 (width - 1))) in
    let room = width - indent in
    if room <= 0 then ""
    else
      let margin = String.make indent ' ' in
      let rule_sgr = Option.value tone ~default:(Theme.border_muted ()) in
      margin ^ paint rule_sgr (repeat_glyph Masc_tui_theme.Box.h room)

let section_header ~width ?(indent = 0) ?subtitle ?right title =
  if width <= 0 then ""
  else
    let indent = max 0 (min indent (max 0 (width - 1))) in
    let room = width - indent in
    if room <= 0 then ""
    else
      let margin = String.make indent ' ' in
      let clean_title = sanitize title in
      let heading_style = Ansi.bold ^ Theme.section_heading () in
      let clean_opt = function
        | None -> None
        | Some s ->
          let t = sanitize s in
          if String.equal (String.trim t) "" then None else Some t
      in
      let clean_sub = clean_opt subtitle in
      let clean_right = clean_opt right in
      let title_cells = cells clean_title in
      if title_cells >= room then
        margin ^ paint heading_style (clamp_plain ~max_cells:room clean_title)
      else
        let sep = " · " in
        let sep_cells = cells sep in
        let rem = ref (room - title_cells) in
        let pieces = ref [] in
        let try_append text =
          if !rem > sep_cells then begin
            let fit = clamp_plain ~max_cells:(!rem - sep_cells) text in
            if not (String.equal fit "") then begin
              rem := !rem - sep_cells - cells fit;
              pieces := paint (Theme.recede ()) (sep ^ fit) :: !pieces
            end
          end
        in
        Option.iter try_append clean_sub;
        Option.iter try_append clean_right;
        margin ^ paint heading_style clean_title
        ^ String.concat "" (List.rev !pieces)

let preview_footer_hints ~width ?(indent = 0) keys =
  if width <= 0 || keys = [] then ""
  else
    let indent = max 0 (min indent (max 0 (width - 1))) in
    let room = width - indent in
    if room <= 0 then ""
    else
      let margin = String.make indent ' ' in
      let key_sgr = Theme.footer_key_style () in
      let label_sgr = Theme.recede () in
      let sep = " · " in
      let sep_cells = cells sep in
      let rendered_sep = paint label_sgr sep in
      let rec collect used_cells acc = function
        | [] -> List.rev acc
        | { Card.key; label } :: rest ->
          let k = String.trim (sanitize key) in
          let l = String.trim (sanitize label) in
          if String.equal k "" && String.equal l "" then
            collect used_cells acc rest
          else
            let part_plain, part_styled =
              if String.equal l "" then (k, paint key_sgr k)
              else if String.equal k "" then (l, paint label_sgr l)
              else (k ^ " " ^ l, paint key_sgr k ^ " " ^ paint label_sgr l)
            in
            let need =
              (if acc = [] then 0 else sep_cells) + cells part_plain
            in
            if used_cells + need <= room then
              collect (used_cells + need) (part_styled :: acc) rest
            else if acc = [] then
              let fitted = clamp_plain ~max_cells:room part_plain in
              [ paint key_sgr fitted ]
            else List.rev acc
      in
      let parts = collect 0 [] keys in
      if parts = [] then "" else margin ^ String.concat rendered_sep parts

let docked_preview ~width ~height ?(indent = 0) ?eyebrow ?title ?meta
    ?(footer_hints = []) body_rows =
  if width <= 0 || height <= 0 then []
  else
    let indent = max 0 (min indent (max 0 (width - 1))) in
    let content_w = max 0 (width - indent) in
    let margin = String.make indent ' ' in
    let clean_opt = function
      | None -> None
      | Some s ->
        let t = String.trim (sanitize s) in
        if String.equal t "" then None else Some t
    in
    let header_line =
      match clean_opt eyebrow, clean_opt title, clean_opt meta with
      | None, None, None -> None
      | Some eye, t_opt, m_opt ->
        Some
          (section_header ~width ~indent ?subtitle:t_opt ?right:m_opt eye)
      | None, Some t, m_opt ->
        Some (section_header ~width ~indent ?subtitle:m_opt t)
      | None, None, Some m ->
        let fit = clamp_plain ~max_cells:content_w m in
        Some (margin ^ paint (Theme.recede ()) fit)
    in
    let rule_line = hairline ~width ~indent () in
    let top_rows =
      match header_line with
      | None -> [ rule_line ]
      | Some hdr -> if height >= 2 then [ rule_line; hdr ] else [ hdr ]
    in
    let top_count = List.length top_rows in
    let footer_row =
      if height - top_count >= 2 then
        let hint_line = preview_footer_hints ~width ~indent footer_hints in
        if String.equal hint_line "" then None else Some hint_line
      else None
    in
    let bottom_rows = match footer_row with Some r -> [ r ] | None -> [] in
    let body_budget = max 0 (height - top_count - List.length bottom_rows) in
    let fit_body_row row =
      let plain = Masc_tui_theme.strip_sgr row in
      let clean_plain = sanitize plain in
      if not (String.equal plain clean_plain) then
        margin ^ clamp_plain ~max_cells:content_w clean_plain
      else if cells plain <= content_w then
        margin ^ row
      else
        margin ^ clamp_plain ~max_cells:content_w plain
    in
    let fitted_body =
      let rec take n acc = function
        | _ when n <= 0 -> List.rev acc
        | [] -> List.rev_append acc (List.init n (fun _ -> ""))
        | r :: rs -> take (n - 1) (fit_body_row r :: acc) rs
      in
      take body_budget [] body_rows
    in
    let combined = top_rows @ fitted_body @ bottom_rows in
    let rec trim_exact n acc = function
      | _ when n <= 0 -> List.rev acc
      | [] -> List.rev_append acc (List.init n (fun _ -> ""))
      | x :: xs -> trim_exact (n - 1) (x :: acc) xs
    in
    trim_exact height [] combined
