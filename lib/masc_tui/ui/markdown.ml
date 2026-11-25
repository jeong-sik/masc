module Glyph = Masc_tui_core.Glyph
module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Grapheme = Masc_tui_term.Grapheme
module Graphics = Masc_tui_term.Graphics
module Cell_grid = Masc_tui_term.Cell_grid

type styled_span = {
  text : string;
  style : Style.t;
  hyperlink : string option;
}

type rendered_line = {
  spans : styled_span list;
  image_part : Cell_grid.document_image_part option;
}

let wrap_styled_spans ~width ~prefix ~continuation spans =
  let width = Int.max 4 width in
  let lines = ref [] in
  let cur = ref (List.rev prefix) in
  let cur_w =
    ref
      (List.fold_left
         (fun a (sp : styled_span) -> a + Grapheme.display_width sp.text)
         0 prefix)
  in
  let cont_w =
    List.fold_left
      (fun a (sp : styled_span) -> a + Grapheme.display_width sp.text)
      0 continuation
  in
  let flush_line () =
    lines := { spans = List.rev !cur; image_part = None } :: !lines;
    cur := List.rev continuation;
    cur_w := cont_w
  in
  let append_span (sp : styled_span) =
    if String.length sp.text > 0 then begin
      cur := sp :: !cur;
      cur_w := !cur_w + Grapheme.display_width sp.text
    end
  in
  (* Break each span on spaces and grapheme boundaries for CJK-safe wrapping. *)
  let emit_word ~style ~hyperlink word =
    let ww = Grapheme.display_width word in
    if !cur_w > cont_w && !cur_w + ww > width then flush_line ();
    if !cur_w + ww <= width then append_span { text = word; style; hyperlink }
    else
      (* Hard-wrap long token on grapheme cluster boundaries. *)
      let buf = Buffer.create (String.length word) in
      let buf_w = ref 0 in
      let flush_buf () =
        if Buffer.length buf > 0 then begin
          append_span { text = Buffer.contents buf; style; hyperlink };
          Buffer.clear buf;
          buf_w := 0
        end
      in
      Grapheme.iter_clusters word (fun ~text ~start_offset ~end_offset ~cell_width ->
          if !cur_w + !buf_w + cell_width > width && (!cur_w > cont_w || !buf_w > 0)
          then begin
            flush_buf ();
            flush_line ()
          end;
          Buffer.add_substring buf text start_offset (end_offset - start_offset);
          buf_w := !buf_w + cell_width);
      flush_buf ()
  in
  List.iter
    (fun (sp : styled_span) ->
      let s = sp.text in
      let len = String.length s in
      let rec scan i =
        if i >= len then ()
        else if Char.equal s.[i] ' ' then begin
          let rec end_sp j =
            if j < len && Char.equal s.[j] ' ' then end_sp (j + 1) else j
          in
          let j = end_sp i in
          let spaces = String.sub s i (j - i) in
          let sw = j - i in
          if !cur_w + sw <= width then
            append_span { text = spaces; style = sp.style; hyperlink = sp.hyperlink }
          else if !cur_w > cont_w then flush_line ();
          scan j
        end
        else begin
          let rec end_word j =
            if j < len && not (Char.equal s.[j] ' ') then end_word (j + 1) else j
          in
          let j = end_word i in
          emit_word ~style:sp.style ~hyperlink:sp.hyperlink (String.sub s i (j - i));
          scan j
        end
      in
      scan 0)
    spans;
  lines := { spans = List.rev !cur; image_part = None } :: !lines;
  List.rev !lines

let pad_line_to_width ~width ~pad_style (line : rendered_line) =
  let used =
    List.fold_left (fun acc (sp : styled_span) -> acc + Grapheme.display_width sp.text) 0 line.spans
  in
  let rem = width - used in
  if rem <= 0 then line
  else
    {
      line with
      spans =
        line.spans
        @ [ { text = String.make rem ' '; style = pad_style; hyperlink = None } ];
    }

let max_inline_mermaid_bytes = 8192
let max_inline_mermaid_lines = 80

let is_diagram_line_cluster = function
  | "\xe2\x94\x80" (* ─ *) | "\xe2\x94\x82" (* │ *) | "\xe2\x94\x8c" (* ┌ *)
  | "\xe2\x94\x90" (* ┐ *) | "\xe2\x94\x94" (* └ *) | "\xe2\x94\x98" (* ┘ *)
  | "\xe2\x94\x9c" (* ├ *) | "\xe2\x94\xa4" (* ┤ *) | "\xe2\x94\xac" (* ┬ *)
  | "\xe2\x94\xb4" (* ┴ *) | "\xe2\x94\xbc" (* ┼ *) | "\xe2\x95\xad" (* ╭ *)
  | "\xe2\x95\xae" (* ╮ *) | "\xe2\x95\xaf" (* ╯ *) | "\xe2\x95\xb0" (* ╰ *)
  | "\xe2\x95\x90" (* ═ *) | "\xe2\x95\x91" (* ║ *) | "\xe2\x95\x94" (* ╔ *)
  | "\xe2\x95\x97" (* ╗ *) | "\xe2\x95\x9a" (* ╚ *) | "\xe2\x95\x9d" (* ╝ *)
  | "\xe2\x95\xa0" (* ╠ *) | "\xe2\x95\xa3" (* ╣ *) | "\xe2\x95\xa6" (* ╦ *)
  | "\xe2\x95\xa9" (* ╩ *) | "\xe2\x95\xac" (* ╬ *) | "\xe2\x95\x93" (* ╓ *)
  | "\xe2\x95\x96" (* ╖ *) | "\xe2\x95\x99" (* ╙ *) | "\xe2\x95\x9c" (* ╜ *)
  | "\xe2\x95\x9f" (* ╟ *) | "\xe2\x95\xa2" (* ╢ *) | "\xe2\x94\x84" (* ┄ *)
  | "\xe2\x94\x86" (* ┆ *) | "\xe2\x94\x81" (* ━ *) | "\xe2\x94\x83" (* ┃ *)
  | "\xe2\x96\xbc" (* ▼ *) | "\xe2\x96\xb2" (* ▲ *) | "\xe2\x96\xb6" (* ▶ *)
  | "\xe2\x97\x80" (* ◀ *) | "\xe2\x96\xba" (* ► *) | "\xe2\x97\x84" (* ◄ *) ->
      true
  | _ -> false

let style_mermaid_row ~line_style ~label_style ~max_width row =
  let clipped =
    if Grapheme.display_width row <= max_width then row
    else Grapheme.truncate_to_width ~max_width row
  in
  let spans = ref [] in
  let cur_buf = Buffer.create (String.length clipped) in
  let cur_is_line = ref None in
  let flush () =
    if Buffer.length cur_buf > 0 then begin
      let style =
        match !cur_is_line with
        | Some true -> line_style
        | Some false | None -> label_style
      in
      spans := { text = Buffer.contents cur_buf; style; hyperlink = None } :: !spans;
      Buffer.clear cur_buf
    end
  in
  Grapheme.iter_clusters clipped (fun ~text ~start_offset ~end_offset ~cell_width:_ ->
      let cluster = String.sub text start_offset (end_offset - start_offset) in
      let is_line = is_diagram_line_cluster cluster in
      (match !cur_is_line with
      | Some prev when Bool.equal prev is_line -> ()
      | Some _ | None ->
          flush ();
          cur_is_line := Some is_line);
      Buffer.add_string cur_buf cluster);
  flush ();
  List.rev !spans

let try_render_mermaid_fence ~inner_w body_lines =
  if inner_w < 8 || List.length body_lines > max_inline_mermaid_lines then None
  else
    let code = String.concat "\n" body_lines in
    if
      String.length code > max_inline_mermaid_bytes
      || String.equal (String.trim code) ""
    then None
    else
      match Mermaid.render_adaptive ~cols:inner_w code with
      | Ok (_ :: _ as rows) -> Some rows
      | Ok [] | Error _ -> None

type fence_kind = Diagram | Score of { rhythm : bool } | Code

let fence_kind tag rest =
  match String.lowercase_ascii tag with
  | "mermaid" | "pele" -> Diagram
  | "alphatex" | "atex" -> Score { rhythm = String.equal rest "rhythm" }
  | _ -> Code

let span style text = { text; style; hyperlink = None }

let spans_width =
  List.fold_left (fun width s -> width + Grapheme.display_width s.text) 0

module Inline = Cmarkit.Inline
module Block = Cmarkit.Block

let bare_url text index =
  let has_prefix prefix =
    let n = String.length prefix in
    index + n <= String.length text
    && String.equal (String.sub text index n) prefix
  in
  has_prefix "https://" || has_prefix "http://" || has_prefix "file://"

let bare_url_end text start =
  let rec scan index parens =
    if index >= String.length text then index
    else
      match text.[index] with
      | ' ' | '\t' | '\n' | '\r' | '<' | '>' | '"' | ']' -> index
      | '(' -> scan (index + 1) (parens + 1)
      | ')' when parens = 0 -> index
      | ')' -> scan (index + 1) (parens - 1)
      | _ -> scan (index + 1) parens
  in
  let rec trim stop =
    if stop <= start then start
    else
      match text.[stop - 1] with
      | '.' | ',' | ';' | ':' | '!' | '?' -> trim (stop - 1)
      | _ -> stop
  in
  trim (scan start 0)

let has_scheme ~name target =
  let length = String.length name in
  String.length target >= length
  && String.equal (String.lowercase_ascii (String.sub target 0 length)) name

let safe_target target =
  not (String.equal target "")
  && not (has_scheme ~name:"data:" target)
  && String.equal (String.trim target) target
  && String.equal (Grapheme.sanitize_controls target) target
  && (not (Inline.Link.is_unsafe target)
      || has_scheme ~name:"file:" target)

let inline_image_def defs inline =
  let image =
    match inline with
    | Inline.Link (node, _) -> Inline.Link.text node
    | other -> other
  in
  match image with
  | Inline.Image (node, _) -> (
      match Inline.Link.reference_definition defs node with
      | Some (Cmarkit.Link_definition.Def (definition, _)) ->
          Option.bind (Cmarkit.Link_definition.dest definition)
            (fun (data_uri, _) -> Graphics.embedded_png_of_uri data_uri)
      | _ -> None)
  | _ -> None

let inline_rows ~(theme : Theme.t) ~defs ~osc8 ~(base : Style.t) inline =
  let rows = ref [] and spans = ref [] in
  let emit style hyperlink text =
    if not (String.equal text "") then
      spans := { text; style; hyperlink } :: !spans
  in
  let newline () =
    rows := List.rev !spans :: !rows;
    spans := []
  in
  let link_style (style : Style.t) =
    Style.make ~fg:(Color.of_rgb theme.status_active) ~bg:style.bg
      ~attrs:Attr.(underline lor style.attrs) ()
  in
  let code_style (style : Style.t) =
    Style.make ~fg:(Color.of_rgb theme.text_bright)
      ~bg:(Color.of_rgb theme.surface_2) ~attrs:style.attrs ()
  in
  let render_text style link text =
    let length = String.length text in
    let rec scan start index =
      if index >= length then emit style link (String.sub text start (index - start))
      else if
        Option.is_none link
        && (match text.[index] with 'h' | 'f' -> bare_url text index | _ -> false)
      then begin
        let stop = bare_url_end text index in
        let uri = String.sub text index (stop - index) in
        if safe_target uri then begin
          emit style link (String.sub text start (index - start));
          emit (link_style style) (Some uri) uri;
          scan stop stop
        end else scan start stop
      end else scan start (index + 1)
    in
    scan 0 0
  in
  let rec render (style : Style.t) link = function
    | Inline.Inlines (children, _) -> List.iter (render style link) children
    | Inline.Text (text, _) ->
        if String.contains text '\n' then
          List.iteri
            (fun index line ->
              if index > 0 then newline ();
              render_text style link line)
            (String.split_on_char '\n' text)
        else render_text style link text
    | Inline.Break _ -> newline ()
    | Inline.Emphasis (em, _) ->
        render (Style.add_attr Attr.italic style) link (Inline.Emphasis.inline em)
    | Inline.Strong_emphasis (em, _) ->
        let strong =
          Style.make ~fg:(Color.of_rgb theme.text_bright) ~bg:style.bg
            ~attrs:Attr.(bold lor style.attrs) ()
        in
        render strong link (Inline.Emphasis.inline em)
    | Inline.Ext_strikethrough (struck, _) ->
        render (Style.add_attr Attr.strike style) link
          (Inline.Strikethrough.inline struck)
    | Inline.Code_span (code, _) -> emit (code_style style) link (Inline.Code_span.code code)
    | Inline.Ext_math_span (math, _) ->
        let delimiter = if Inline.Math_span.display math then "$$" else "$" in
        emit (code_style style) link (delimiter ^ Inline.Math_span.tex math ^ delimiter)
    | Inline.Autolink (auto, _) ->
        let label, _ = Inline.Autolink.link auto in
        let target = if Inline.Autolink.is_email auto then "mailto:" ^ label else label in
        if safe_target target then emit (link_style style) (Some target) label
        else emit style link label
    | Inline.Link (node, _) -> render_link style link ~image:false node
    | Inline.Image (node, _) -> render_link style link ~image:true node
    | Inline.Raw_html (lines, _) ->
        List.iteri
          (fun index line ->
            if index > 0 then newline ();
            emit style link (Cmarkit.Block_line.tight_to_string line))
          lines
    | _ -> ()
  and render_link (style : Style.t) enclosing ~image node =
    let label = Inline.Link.text node in
    let definition = Inline.Link.reference_definition defs node in
    let target =
      match definition with
      | Some (Cmarkit.Link_definition.Def (definition, _)) -> (
          match Cmarkit.Link_definition.dest definition with
          | Some (url, _) when safe_target url -> Some url
          | Some _ | None -> None)
      | _ -> None
    in
    let link =
      if image && Option.is_some enclosing then enclosing
      else Option.fold ~none:enclosing ~some:Option.some target
    in
    let styled = if Option.is_some link then link_style style else style in
    if image then
      emit styled link (if Inline.is_empty label then "▧" else "▧ ");
    (match definition with
    | Some (Block.Footnote.Def _) ->
        emit styled link "[";
        render styled link label;
        emit styled link "]"
    | _ -> render styled link label);
    if not osc8 then
      Option.iter
        (fun url -> emit (Typography.whisper ~bg:style.bg theme) None (" (" ^ url ^ ")"))
        target
  in
  render base None inline;
  newline ();
  List.rev !rows

type line_prefix = {
  first : styled_span;
  rest : styled_span;
  first_row : int;
}

type line_layout = {
  base : Style.t;
  prefixes : line_prefix list;
}

let fit_prefix ~width select layout =
  let rec fit remaining visible = function
    | [] -> visible
    | _ when remaining <= 0 -> visible
    | prefix :: rest ->
        let span = select prefix in
        let used = Grapheme.display_width span.text in
        if used <= remaining then fit (remaining - used) (span :: visible) rest
        else visible
  in
  fit width [] layout.prefixes

(* Cmarkit 0.4.0 reparses each nested link label while looking for a valid
   destination. Deep bracket runs have exponential cost, even when the text
   has no link. Bound that recursion before using it on a live UI frame. *)
let safe_link_depth raw =
  let max_link_depth = 8 in
  let length = String.length raw in
  let rec backtick_run_end i =
    if i < length && raw.[i] = '`' then backtick_run_end (i + 1) else i
  in
  (* The next equal-width run closes a code span. Index it once so many
     unmatched runs take linear time too. Table cells parse independently. *)
  let code_closers = lazy (
    let closers = Hashtbl.create 16 in
    let previous = Hashtbl.create 8 in
    let rec index i =
      if i < length then
        match raw.[i] with
        | '\n' | '\r' | '|' ->
            Hashtbl.reset previous;
            index (i + 1)
        | '`' ->
            let next = backtick_run_end (i + 1) in
            let width = next - i in
            Option.iter
              (fun opener -> Hashtbl.add closers opener next)
              (Hashtbl.find_opt previous width);
            Hashtbl.replace previous width i;
            index next
        | _ -> index (i + 1)
    in
    index 0;
    closers)
  in
  let rec skip_indent i =
    if i < length && (raw.[i] = ' ' || raw.[i] = '\t') then skip_indent (i + 1)
    else i
  in
  let starts_item i =
    (i = 0 || raw.[i - 1] = '\n' || raw.[i - 1] = '\r')
    && i + 1 < length && (raw.[i + 1] = ' ' || raw.[i + 1] = '\t')
    && let content = skip_indent (i + 1) in
       content < length && raw.[content] <> '\n' && raw.[content] <> '\r'
  in
  let rec scan i depth blank opaque =
    if i >= length then true
    else
      match raw.[i] with
      | ('-' | '+' | '*') when starts_item i ->
          (* An unindented nonempty bullet interrupts the previous paragraph.
             Even adjacent tight-list items use independent inline parse state. *)
          scan (i + 1) 0 false false
      | '[' -> depth < max_link_depth && scan (i + 1) (depth + 1) false opaque
      | ']' ->
          (* These inline atoms may contain a literal closer. Count conservatively
             until the paragraph ends instead of trying to lex them twice. *)
          let depth = if opaque then depth else Int.max 0 (depth - 1) in
          scan (i + 1) depth false opaque
      | '`' ->
          (match Hashtbl.find_opt (Lazy.force code_closers) i with
          | Some next -> scan next depth false opaque
          | None -> scan (backtick_run_end (i + 1)) depth false (opaque || depth > 0))
      | '<' | '$' -> scan (i + 1) depth false (opaque || depth > 0)
      | '\\' when i + 1 < length ->
          (match raw.[i + 1] with
          | '[' | ']' | '\\' -> scan (i + 2) depth false opaque
          | '`' ->
              let next = backtick_run_end (i + 2) in
              (* An escaped run may open with a different width. Keep the
                 conservative paragraph fallback for that case. *)
              scan next depth false (opaque || (next > i + 2 && depth > 0))
          | _ -> scan (i + 1) depth false opaque)
      | '\n' | '\r' ->
          let next =
            if raw.[i] = '\r' && i + 1 < length && raw.[i + 1] = '\n' then i + 2
            else i + 1
          in
          if blank then scan next 0 true false else scan next depth true opaque
      | ' ' | '\t' -> scan (i + 1) depth blank opaque
      | _ -> scan (i + 1) depth false opaque
  in
  scan 0 0 true false

let render_literal ~width ~base_style raw =
  let width = Int.max 4 width in
  String.split_on_char '\n' raw
  |> List.concat_map (fun line ->
         let rows = ref [] and cells = ref 0 in
         let row = Buffer.create (Int.min width (String.length line)) in
         let push_row () =
           rows :=
             { spans = [ span base_style (Buffer.contents row) ]; image_part = None }
             :: !rows;
           Buffer.clear row;
           cells := 0
         in
         Grapheme.iter_clusters line
           (fun ~text ~start_offset ~end_offset ~cell_width ->
             if !cells + cell_width > width then push_row ();
             Buffer.add_substring row text start_offset (end_offset - start_offset);
             cells := !cells + cell_width);
         push_row ();
         List.rev !rows)

let source_lines raw meta =
  let loc = Cmarkit.Meta.textloc meta in
  if Cmarkit.Textloc.is_none loc || Cmarkit.Textloc.is_empty loc then []
  else
    let first = Cmarkit.Textloc.first_byte loc in
    let last = Cmarkit.Textloc.last_byte loc in
    String.sub raw first (last - first + 1)
    |> String.split_on_char '\n'
    |> List.map (fun line ->
           if String.ends_with ~suffix:"\r" line then
             String.sub line 0 (String.length line - 1)
           else line)

(* Cmarkit's table extension requires both outer pipes. Preserve tables with
   optional outer pipes by retrying just the paragraph, outside code/HTML. *)
let table_without_outer_pipes ~defs raw meta =
  let has_pipe line = String.contains line '|' in
  let full_row line =
    String.starts_with ~prefix:"|" line && String.ends_with ~suffix:"|" line
  in
  let is_rule line =
    String.contains line '-'
    && String.for_all (function '|' | '-' | ':' | ' ' | '\t' -> true | _ -> false) line
  in
  let normalize line =
    let line = String.trim line in
    let line = if String.starts_with ~prefix:"|" line then line else "| " ^ line in
    if String.ends_with ~suffix:"|" line then line else line ^ " |"
  in
  match List.map String.trim (source_lines raw meta) with
  | header :: rule :: rest when has_pipe header && is_rule rule
      && not (full_row header && full_row rule) ->
      let rec table_rows = function
        | row :: tail when has_pipe row -> normalize row :: table_rows tail
        | lines -> lines
      in
      let source = String.concat "\n" (normalize header :: normalize rule :: table_rows rest) in
      let parsed = Cmarkit.Doc.of_string ~defs ~strict:false source |> Cmarkit.Doc.block in
      (match parsed with
      | Block.Ext_table _ | Block.Blocks (Block.Ext_table _ :: _, _) -> Some parsed
      | _ -> None)
  | _ -> None

let referenced_labels doc =
  let module Folder = Cmarkit.Folder in
  let module Labels = Cmarkit.Label.Map in
  let inline folder used = function
    | Inline.Link (node, _) | Inline.Image (node, _) ->
        let used =
          match Inline.Link.referenced_label node with
          | None -> used
          | Some label -> Labels.add (Cmarkit.Label.key label) () used
        in
        Folder.ret (Folder.fold_inline folder used (Inline.Link.text node))
    | _ -> Folder.default
  in
  Folder.fold_doc (Folder.make ~inline ()) Labels.empty doc

let alphatex_code_blocks raw =
  let module Folder = Cmarkit.Folder in
  let doc = Cmarkit.Doc.of_string ~strict:false ~locs:false raw in
  let block _folder acc = function
    | Block.Code_block (code, _) ->
        let closed =
          match Block.Code_block.layout code with
          | `Fenced { closing_fence; _ } -> Option.is_some closing_fence
          | `Indented -> false
        in
        let lang_tag, info_tail =
          Option.bind (Block.Code_block.info_string code) (fun (info, _) ->
              Block.Code_block.language_of_info_string info)
          |> Option.value ~default:("", "")
        in
        let acc =
          match fence_kind lang_tag info_tail, closed with
          | Score _, true ->
              let body =
                Block.Code_block.code code
                |> List.map Cmarkit.Block_line.to_string
                |> String.concat "\n"
              in
              body :: acc
          | Score _, false | (Diagram | Code), (true | false) -> acc
        in
        Folder.ret acc
    | _ -> Folder.default
  in
  Folder.fold_doc (Folder.make ~block ()) [] doc |> List.rev

let render_document ~(theme : Theme.t) ~width ~osc8 ~(base_style : Style.t) raw =
  let bg = base_style.bg in
  let muted_style = Typography.whisper ~bg ~italic:false theme in
  let hairline_style = Style.make ~fg:(Color.of_rgb theme.border_subtle) ~bg () in
  let quote_rail_style = Style.make ~fg:(Color.of_rgb theme.border_inactive) ~bg () in
  let locs = String.contains raw '|' || String.contains raw '[' in
  let doc = Cmarkit.Doc.of_string ~strict:false ~locs raw in
  let defs = Cmarkit.Doc.defs doc in
  let used_labels =
    if Cmarkit.Label.Map.is_empty defs then Cmarkit.Label.Map.empty
    else referenced_labels doc
  in
  let out = ref [] and row_count = ref 0 in
  let push_lines lines =
    row_count := !row_count + List.length lines;
    out := List.rev_append lines !out
  in
  let inset layout ~first ~rest =
    { layout with prefixes = { first; rest; first_row = !row_count } :: layout.prefixes }
  in
  let fit = fit_prefix ~width:(width - 4) in
  let prefix layout =
    fit (fun p -> if p.first_row = !row_count then p.first else p.rest) layout
  in
  let continuation layout = fit (fun p -> p.rest) layout in
  let wrap layout spans =
    wrap_styled_spans ~width ~prefix:(prefix layout)
      ~continuation:(continuation layout) spans
  in
  let draw_rows layout rows = List.iter (fun row -> push_lines (wrap layout row)) rows in
  let draw_inlines layout inline =
    inline_rows ~theme ~defs ~osc8 ~base:layout.base inline |> draw_rows layout
  in
  let attach_image ~source ~left_inset ~start =
    let count = !row_count - start in
    if count > 0 then begin
      let rows : Cell_grid.document_image_rows = { source; count } in
      let rec attach index = function
        | line :: tail when index >= 0 ->
            { line with image_part = Some { rows; index; left_inset } }
            :: attach (index - 1) tail
        | tail -> tail
      in
      out := attach (count - 1) !out
    end
  in
  let draw_embedded_image layout image =
    let left_inset = spans_width (continuation layout) in
    let cols = width - left_inset in
    let start = !row_count in
    let height =
      Int.min 8 (Int.max 3 ((cols * image.Graphics.height / image.width + 1) / 2))
    in
    let geometry =
      Printf.sprintf "%d×%d px" image.width image.height
      |> span (Typography.whisper ~bg theme)
    in
    draw_rows layout ([ geometry ] :: List.init (height - 1) (fun _ -> []));
    attach_image ~source:(Embedded_png image) ~left_inset ~start
  in
  let draw_rule layout requested_width =
    let prefix = prefix layout in
    let count = Int.min requested_width (width - spans_width prefix) in
    let rule = String.concat "" (List.init count (fun _ -> Glyph.to_utf8 Glyph.Box_h)) in
    push_lines [ { spans = prefix @ [ span hairline_style rule ]; image_part = None } ]
  in
  let draw_code layout code =
    let lang_tag, info_tail =
      Option.bind (Block.Code_block.info_string code)
        (fun (info, _) -> Block.Code_block.language_of_info_string info)
      |> Option.value ~default:("", "")
    in
    let closed =
      match Block.Code_block.layout code with
      | `Fenced { closing_fence; _ } -> Option.is_some closing_fence
      | `Indented -> false
    in
    let body_lines = List.map Cmarkit.Block_line.to_string (Block.Code_block.code code) in
    let code_bg = Color.of_rgb theme.surface_0 in
    let code_pad = Typography.primary ~bg:code_bg theme in
    let gutter =
      span (Style.make ~fg:(Color.of_rgb theme.border_subtle) ~bg:code_bg ())
        (Glyph.to_utf8 Glyph.Left_rail ^ " ")
    in
    let layout = inset layout ~first:gutter ~rest:gutter in
    let inner_w = width - spans_width (continuation layout) in
    let draw rows =
      List.iter
        (fun spans ->
          wrap layout spans
          |> List.map (pad_line_to_width ~width ~pad_style:code_pad)
          |> push_lines)
        rows
    in
    if not (String.equal lang_tag "") then
      draw [ [ span (Typography.whisper ~bg:code_bg theme) lang_tag ] ];
    let body_start = !row_count in
    let kind = fence_kind lang_tag info_tail in
    let rendered =
      match kind, closed with
      | Diagram, true -> (
          match try_render_mermaid_fence ~inner_w body_lines with
          | None -> false
          | Some rows ->
              let line_style =
                Style.make ~fg:(Color.of_rgb theme.status_active) ~bg:code_bg ()
              in
              let label_style =
                Style.make ~fg:(Color.of_rgb theme.text_bright) ~bg:code_bg ()
              in
              draw (List.map (style_mermaid_row ~line_style ~label_style ~max_width:inner_w) rows);
              true)
      | Score { rhythm }, true -> (
          let source = String.concat "\n" body_lines in
          match Alphatex.render_tab ~rhythm ~max_width:inner_w source with
          | Ok rows ->
              draw (List.map (fun row -> [ span code_pad row ]) rows);
              true
          | Error reason ->
              let style = Typography.status ~bg:code_bg theme Theme.Status_attention in
              draw [ [ span style (Alphatex.failure_text reason) ] ];
              false)
      | (Diagram | Score _), false | Code, _ -> false
    in
    if not rendered then begin
      Code_lexer.rows_of_source ~language:(Code_lexer.language_of_tag lang_tag)
        (String.concat "\n" body_lines)
      |> List.map
           (List.map (fun (seg : Code_lexer.segment) ->
                span (Code_lexer.style_of_token ~theme ~bg:code_bg seg.kind) seg.text))
      |> draw
    end;
    (match kind, closed with
    | Diagram, true
      when List.length body_lines <= max_inline_mermaid_lines ->
        let source = String.concat "\n" body_lines in
        if String.length source <= max_inline_mermaid_bytes && !row_count - body_start >= 2 then
          attach_image ~source:(Mermaid source) ~left_inset:(width - inner_w) ~start:body_start
    | (Diagram | Score _ | Code), _ -> ())
  in
  let draw_table layout table =
    let separator = span hairline_style (" " ^ Glyph.to_utf8 Glyph.Box_v ^ " ") in
    let row_width = width - spans_width (continuation layout) in
    let columns = Block.Table.col_count table in
    let column_width = (row_width - (3 * (columns - 1))) / Int.max 1 columns in
    let header_style =
      Typography.structure ~bg:(Color.of_rgb theme.surface_2) ~bold:true theme
    in
    let cell_rows style content =
      inline_rows ~theme ~defs ~osc8 ~base:style content
      |> List.concat_map (wrap_styled_spans ~width:column_width ~prefix:[] ~continuation:[])
    in
    let draw_cells style cells =
      let cells = List.map fst cells in
      if column_width < 4 then begin
        draw_rule layout row_width;
        List.iter
          (fun cell ->
            let marker = span hairline_style (Glyph.to_utf8 Glyph.Box_v ^ " ") in
            let padding = span style "  " in
            let cell_layout = inset layout ~first:marker ~rest:padding in
            draw_inlines { cell_layout with base = style } cell)
          cells
      end else
        let cells = List.filteri (fun i _ -> i < columns) cells in
        let wrapped = List.map (cell_rows style) cells in
        let wrapped = wrapped @ List.init (columns - List.length cells) (fun _ -> []) in
        let rec join = function
          | [] -> ()
          | rows when List.for_all (function [] -> true | _ :: _ -> false) rows -> ()
          | rows ->
              let visible, remaining =
                List.split
                  (List.map
                     (function
                       | [] -> { spans = []; image_part = None }, []
                       | current :: rest -> current, rest)
                     rows)
              in
              let parts =
                List.map
                  (fun line -> (pad_line_to_width ~width:column_width ~pad_style:style line).spans)
                  visible
              in
              let prefix = prefix layout in
              let rec join_cells = function
                | [] -> []
                | [ cell ] -> cell
                | cell :: rest -> cell @ (separator :: join_cells rest)
              in
              let spans = prefix @ join_cells parts in
              push_lines [ { spans; image_part = None } ];
              join remaining
        in
        join wrapped
    in
    List.iter
      (fun ((row, _), _) ->
        match row with
        | `Header cells -> draw_cells header_style cells
        | `Sep _ -> if column_width >= 4 then draw_rule layout row_width
        | `Data cells -> draw_cells layout.base cells)
      (Block.Table.rows table)
  in
  let rec render layout = function
    | Block.Blocks (blocks, _) -> List.iter (render layout) blocks
    | Block.Blank_line _ -> draw_rows layout [ [] ]
    | Block.Paragraph (p, meta) -> (
        match table_without_outer_pipes ~defs raw meta with
        | Some table -> render layout table
        | None ->
            let inline = Block.Paragraph.inline p in
            draw_inlines layout inline;
            Option.iter (draw_embedded_image layout) (inline_image_def defs inline))
    | Block.Block_quote (quote, _) ->
        let rail = span quote_rail_style (Glyph.to_utf8 Glyph.Left_rail ^ " ") in
        let quoted = inset layout ~first:rail ~rest:rail in
        render { quoted with base = Typography.whisper ~bg theme } (Block.Block_quote.block quote)
    | Block.Heading (h, _) ->
        let level = Block.Heading.level h in
        let inline = Block.Heading.inline h in
        let style =
          if level <= 2 then Typography.anchor ~bg theme
          else Typography.structure ~bg ~bold:true theme
        in
        draw_inlines { layout with base = style } inline;
        if level = 1 then begin
          let text = String.concat " " (Inline.to_plain_text ~break_on_soft:false inline |> List.map (String.concat "")) in
          draw_rule layout (Int.max 12 (Grapheme.display_width text + 2))
        end
    | Block.Thematic_break _ -> draw_rule layout width
    | Block.Code_block (code, _) | Block.Ext_math_block (code, _) -> draw_code layout code
    | Block.Html_block (lines, _) ->
        List.map (fun (text, _) -> [ span layout.base text ]) lines |> draw_rows layout
    | Block.List (items, _) -> List.iter (render_item layout) (Block.List'.items items)
    | Block.Ext_table (table, _) -> draw_table layout table
    | Block.Ext_footnote_definition (footnote, _) ->
        let label = "[" ^ Cmarkit.Label.text_to_string (Block.Footnote.label footnote) ^ "]: " in
        render (hanging layout (Typography.structure ~bg theme) label)
          (Block.Footnote.block footnote)
    | Block.Link_reference_definition (definition, meta) ->
        let referenced =
          Cmarkit.Link_definition.defined_label definition
          |> Option.exists (fun label ->
                 Cmarkit.Label.Map.mem (Cmarkit.Label.key label) used_labels)
        in
        (* Log lines such as "[ERROR]: timeout" also parse as definitions. *)
        if not referenced then
          source_lines raw meta
          |> List.map (fun text -> [ span layout.base text ])
          |> draw_rows layout
    | _ -> ()
  and hanging layout style text =
    let first = span style text in
    let rest = span layout.base (String.make (Grapheme.display_width text) ' ') in
    inset layout ~first ~rest
  and render_item layout (item, _) =
    let glyph marker = Glyph.to_utf8 marker in
    let marker, style =
      match Block.List_item.ext_task_marker item with
      | Some (codepoint, _) -> (
          match Block.List_item.task_status_of_task_marker codepoint with
          | `Checked -> glyph Glyph.Check_mark, Typography.status ~bg ~bold:true theme Theme.Status_ok
          | `Unchecked -> glyph Glyph.Live_idle, muted_style
          | `Cancelled -> "−", muted_style
          | `Other marker ->
              let text = Buffer.create 4 in
              Buffer.add_utf_8_uchar text marker;
              Buffer.contents text, muted_style)
      | None ->
          let marker, _ = Block.List_item.marker item in
          match marker with
          | "-" | "*" | "+" -> glyph Glyph.Separator_dot, Typography.accent ~bg ~bold:true theme
          | marker -> marker, Typography.structure ~bg theme
    in
    let inner = hanging layout style (marker ^ " ") in
    match Block.List_item.block item with
    | Block.Blocks ([], _) -> draw_rows inner [ [] ]
    | body -> render inner body
  in
  let layout = { base = base_style; prefixes = [] } in
  render layout (Cmarkit.Doc.block doc);
  match !out with
  | [] -> [ { spans = []; image_part = None } ]
  | rows -> List.rev rows

let md_render_cache_mu = Stdlib.Mutex.create ()
let md_render_cache :
    (Theme.t * Style.t * int * bool * string, rendered_line list)
    Hashtbl.t =
  Hashtbl.create 128

let md_render_cache_bytes = ref 0
let max_md_render_cache_entries = 256
let max_md_render_cache_entry_bytes = 524_288
let max_md_render_cache_total_bytes = 4 * 1024 * 1024

let render_lines_uncached ~(theme : Theme.t) ~width ?(osc8 = true) ?base_style raw =
  let width = Int.max 8 width in
  let base_style = Option.value base_style ~default:(Typography.primary theme) in
  if safe_link_depth raw then render_document ~theme ~width ~osc8 ~base_style raw
  else render_literal ~width ~base_style raw

let render_lines ~(theme : Theme.t) ~width ?(osc8 = true) ?base_style raw =
  let width = Int.max 8 width in
  let base_style = Option.value base_style ~default:(Typography.primary theme) in
  let raw_bytes = String.length raw in
  if raw_bytes > max_md_render_cache_entry_bytes then
    render_lines_uncached ~theme ~width ~osc8 ~base_style raw
  else
    let key = (theme, base_style, width, osc8, raw) in
    match
      Stdlib.Mutex.protect md_render_cache_mu (fun () ->
          Hashtbl.find_opt md_render_cache key)
    with
    | Some hit -> hit
    | None ->
        let rendered = render_lines_uncached ~theme ~width ~osc8 ~base_style raw in
        Stdlib.Mutex.protect md_render_cache_mu (fun () ->
            if
              Hashtbl.length md_render_cache >= max_md_render_cache_entries
              || !md_render_cache_bytes + raw_bytes > max_md_render_cache_total_bytes
            then begin
              Hashtbl.clear md_render_cache;
              md_render_cache_bytes := 0
            end;
            if not (Hashtbl.mem md_render_cache key) then
              md_render_cache_bytes := !md_render_cache_bytes + raw_bytes;
            Hashtbl.replace md_render_cache key rendered);
        rendered

let draw_line grid ~(rect : Rect.t) ?(osc8 = true) (line : rendered_line) =
  let x = ref rect.x in
  List.iter
    (fun (span : styled_span) ->
      if !x < Rect.right rect && String.length span.text > 0 then begin
        let style =
          match (osc8, span.hyperlink) with
          | true, Some uri ->
              Style.with_hyperlink (Cell_grid.intern_hyperlink grid uri) span.style
          | _ -> span.style
        in
        x := !x + Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y ~style span.text
      end)
    line.spans;
  Option.iter (Cell_grid.register_document_image_part grid ~rect) line.image_part

let draw grid ~(rect : Rect.t) ~(theme : Theme.t) ?(osc8 = true) ?(scroll = 0)
    raw =
  if Rect.is_empty rect then 0
  else
    let lines = render_lines ~theme ~width:rect.w ~osc8 raw in
    let total = List.length lines in
    let arr = Array.of_list lines in
    let max_start = Int.max 0 (total - rect.h) in
    let start = Int.max 0 (Int.min max_start scroll) in
    let visible = Int.min rect.h (total - start) in
    let bg = Color.of_rgb theme.surface_1 in
    let clear_style = Typography.primary ~bg theme in
    for i = 0 to visible - 1 do
      let py = rect.y + i in
      let row_rect = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
      Cell_grid.fill_rect ~clip:rect grid ~rect:row_rect ~style:clear_style ();
      draw_line grid ~rect:row_rect ~osc8 arr.(start + i)
    done;
    total
