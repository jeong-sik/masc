type skill_tone =
  | Skill_live
  | Skill_used
  | Skill_attention
  | Skill_failure

type style =
  | User
  | Inbound
  | Keeper
  | Status
  | Journal
  | Error
  | Tool
  | Skill of skill_tone
  | Thinking

type markdown_source =
  | Markdown_stable of {
      keeper_name : string;
      request_id : string;
      observed_at : float;
      entry_index : int;
    }
  | Markdown_growing of {
      keeper_name : string;
      request_id : string;
      entry_index : int;
    }
  | Markdown_streaming

type timeline_bucket = {
  tb_year : int;
  tb_month : int;
  tb_day : int;
  tb_hour : int;
  tb_is_dst : bool;
}

type entry = {
  style : style;
  timestamp : string;
  timeline_bucket : timeline_bucket option;
  role_label : string;
  role_label_mark_cells : int;
  request_label : string;
  body : string;
  markdown_source : markdown_source;
}

type metadata =
  | Timeline_break of timeline_bucket
  | Origin of {
      timestamp : string;
      role_label : string;
      request_label : string;
    }
  | Continued_at of { timestamp : string }

type row_kind =
  | Metadata of metadata
  | Body
  | Viewport_gap of { hidden_rows : int }

type origin_display =
  | Origin_row
  | Origin_inline
  | Origin_bare

type shade =
  | Shade_none
  | Shade_quoted

type row = {
  style : style;
  kind : row_kind;
  shade : shade;
  text : string;
  gutter_label_at : int;
  gutter : string;
}

let utf8_scalar_byte_length first =
  let byte = Char.code first in
  if byte < 0x80 then Some 1
  else if byte >= 0xC2 && byte <= 0xDF then Some 2
  else if byte >= 0xE0 && byte <= 0xEF then Some 3
  else if byte >= 0xF0 && byte <= 0xF4 then Some 4
  else None

let is_single_utf8_scalar text =
  if String.equal text "" || not (String.is_valid_utf_8 text) then false
  else
    let decoded = String.get_utf_8_uchar text 0 in
    Uchar.utf_decode_is_valid decoded
    && Uchar.utf_decode_length decoded = String.length text

let is_printable_utf8_scalar text =
  if not (is_single_utf8_scalar text) then false
  else
    let code =
      String.get_utf_8_uchar text 0 |> Uchar.utf_decode_uchar |> Uchar.to_int
    in
    code >= 0x20 && code <> 0x7F && not (code >= 0x80 && code <= 0x9F)

let drop_last_utf8_scalar text =
  if String.equal text "" || not (String.is_valid_utf_8 text) then text
  else
    let length = String.length text in
    let rec find_last offset previous =
      if offset >= length then previous
      else
        let scalar_length =
          String.get_utf_8_uchar text offset |> Uchar.utf_decode_length
        in
        find_last (offset + scalar_length) offset
    in
    String.sub text 0 (find_last 0 0)

let ansi_csi_end text offset =
  let length = String.length text in
  if offset + 1 >= length || text.[offset] <> '\x1B' || text.[offset + 1] <> '['
  then None
  else
    let rec scan index =
      if index >= length then None
      else
        let byte = Char.code text.[index] in
        if byte >= 0x40 && byte <= 0x7E then Some (index + 1)
        else if byte >= 0x20 && byte <= 0x3F then scan (index + 1)
        else None
    in
    scan (offset + 2)

let scalar_cell_width scalar =
  let code = Uchar.to_int scalar in
  if code >= 0x20 && code <= 0x7E then 1
  else if Uucp.Func.is_regional_indicator scalar then 1
  else if Uucp.Emoji.is_emoji_presentation scalar then 2
  else max 0 (Uucp.Break.tty_width_hint scalar)

type display_piece = {
  start_offset : int;
  end_offset : int;
  cell_width : int;
  ansi : bool;
}

let scalar_pieces text start_offset end_offset reversed =
  let rec loop offset reversed =
    if offset >= end_offset then reversed
    else
      let decoded = String.get_utf_8_uchar text offset in
      let valid = Uchar.utf_decode_is_valid decoded in
      let scalar_length = max 1 (Uchar.utf_decode_length decoded) in
      let next = min end_offset (offset + scalar_length) in
      let width =
        if valid then scalar_cell_width (Uchar.utf_decode_uchar decoded) else 1
      in
      loop next
        ({ start_offset = offset;
           end_offset = next;
           cell_width = width;
           ansi = false;
         }
        :: reversed)
  in
  loop start_offset reversed

(* [String.is_valid_utf_8] wants a string of its own, and taking one meant
   copying the run before a single width was read. This asks the same question
   of the range in place. A scalar that would reach past [end_offset] is the
   truncated tail the copy would have rejected too. *)
let valid_utf_8_range text start_offset end_offset =
  let rec loop offset =
    if offset >= end_offset then true
    else
      let decoded = String.get_utf_8_uchar text offset in
      if not (Uchar.utf_decode_is_valid decoded) then false
      else
        let length = Uchar.utf_decode_length decoded in
        if offset + length > end_offset then false else loop (offset + length)
  in
  loop start_offset

(* What a piece needs is a byte span and a width, and neither needs the cluster
   to exist as a string. Going through [Uuseg_string.fold_utf_8] re-encoded
   every scalar into a buffer and cut a string out of it at each boundary --
   one allocation per character on screen, thrown away as soon as it was
   measured. The segmenter is driven directly here and the spans are read off
   [text]. The width is the same fold [grapheme_cell_width] did over the
   cluster, run as the scalars arrive. *)
let grapheme_pieces text start_offset end_offset reversed =
  if start_offset >= end_offset then reversed
  else if not (valid_utf_8_range text start_offset end_offset) then
    scalar_pieces text start_offset end_offset reversed
  else begin
    let segmenter = Uuseg.create `Grapheme_cluster in
    let pieces = ref reversed in
    let cluster_start = ref start_offset in
    let cluster_end = ref start_offset in
    let width = ref 0 in
    let widest = ref 0 in
    let hangul_l = ref false in
    let hangul_vt = ref false in
    let close_cluster () =
      if !cluster_end > !cluster_start then begin
        let cells = if !hangul_l && !hangul_vt then !widest else !width in
        pieces :=
          { start_offset = !cluster_start;
            end_offset = !cluster_end;
            cell_width = cells;
            ansi = false;
          }
          :: !pieces;
        cluster_start := !cluster_end;
        width := 0;
        widest := 0;
        hangul_l := false;
        hangul_vt := false
      end
    in
    let take_scalar scalar =
      cluster_end := !cluster_end + Uchar.utf_8_byte_length scalar;
      let scalar_width = scalar_cell_width scalar in
      width := !width + scalar_width;
      widest := max !widest scalar_width;
      let hangul_type = Uucp.Hangul.syllable_type scalar in
      hangul_l := !hangul_l || hangul_type = `L;
      hangul_vt := !hangul_vt || hangul_type = `V || hangul_type = `T
    in
    let rec drain event =
      match Uuseg.add segmenter event with
      | `Uchar scalar ->
          take_scalar scalar;
          drain `Await
      | `Boundary ->
          close_cluster ();
          drain `Await
      | `Await | `End -> ()
    in
    let rec feed offset =
      if offset >= end_offset then begin
        drain `End;
        close_cluster ()
      end
      else
        let decoded = String.get_utf_8_uchar text offset in
        drain (`Uchar (Uchar.utf_decode_uchar decoded));
        feed (offset + Uchar.utf_decode_length decoded)
    in
    feed start_offset;
    !pieces
  end

let display_pieces text =
  let length = String.length text in
  (* Only an escape can open a sequence, so the scan jumps to the next escape
     rather than asking at every byte of every rendered line. *)
  let rec find_ansi offset =
    if offset >= length then None
    else
      match String.index_from_opt text offset '\x1B' with
      | None -> None
      | Some escape -> (
          match ansi_csi_end text escape with
          | Some next -> Some (escape, next)
          | None -> find_ansi (escape + 1))
  in
  let rec loop offset reversed =
    match find_ansi offset with
    | None -> List.rev (grapheme_pieces text offset length reversed)
    | Some (ansi_start, ansi_end) ->
        let reversed =
          grapheme_pieces text offset ansi_start reversed
        in
        loop ansi_end
          ({ start_offset = ansi_start;
             end_offset = ansi_end;
             cell_width = 0;
             ansi = true;
           }
          :: reversed)
  in
  loop 0 []

let pieces_width pieces =
  List.fold_left (fun width piece -> width + piece.cell_width) 0 pieces

(* Segmenting the text is what these cost, so the callers below that need both
   a measurement and a cut take the pieces once and pass them along. Measuring
   through [display_width] and then cutting through [cell_prefix] segmented
   every rendered line twice. *)
let cell_prefix_of_pieces text pieces max_cells =
  let buffer = Buffer.create (String.length text) in
  let rec loop used_cells saw_ansi = function
    | [] -> Buffer.contents buffer, used_cells, saw_ansi
    | piece :: rest when piece.ansi ->
        Buffer.add_substring buffer text piece.start_offset
          (piece.end_offset - piece.start_offset);
        loop used_cells true rest
    | piece :: rest when used_cells + piece.cell_width <= max_cells ->
        Buffer.add_substring buffer text piece.start_offset
          (piece.end_offset - piece.start_offset);
        loop (used_cells + piece.cell_width) saw_ansi rest
    | _ -> Buffer.contents buffer, used_cells, saw_ansi
  in
  loop 0 false pieces

let cell_suffix_of_pieces text pieces max_cells =
  let rec start_offset used current_start = function
    | [] -> current_start
    | piece :: rest when used + piece.cell_width <= max_cells ->
        start_offset (used + piece.cell_width) piece.start_offset rest
    | _ -> current_start
  in
  let start =
    start_offset 0 (String.length text) (List.rev pieces)
  in
  let rec drop_detached_zero_width = function
    | [] -> String.length text
    | piece :: rest when piece.end_offset <= start ->
        drop_detached_zero_width rest
    | piece :: rest when piece.ansi || piece.cell_width = 0 ->
        drop_detached_zero_width rest
    | piece :: _ -> piece.start_offset
  in
  let start = drop_detached_zero_width pieces in
  String.sub text start (String.length text - start)

let display_width text = pieces_width (display_pieces text)

let cell_prefix text max_cells =
  cell_prefix_of_pieces text (display_pieces text) max_cells

(* Drop the first [cells] display cells, keeping every ANSI sequence crossed
   so the remainder opens under the styles the cut passed through. A wide
   grapheme straddling the boundary is dropped whole and its remaining cells
   are padded with spaces, so the columns to the right stay aligned. *)
let drop_cells text cells =
  if cells <= 0 then text
  else
    let pieces = display_pieces text in
    let buffer = Buffer.create (String.length text) in
    let rec loop dropped = function
      | [] -> ()
      | piece :: rest when piece.ansi ->
          Buffer.add_substring buffer text piece.start_offset
            (piece.end_offset - piece.start_offset);
          loop dropped rest
      | piece :: rest when dropped + piece.cell_width <= cells ->
          loop (dropped + piece.cell_width) rest
      | piece :: rest when dropped < cells ->
          Buffer.add_string buffer
            (String.make (dropped + piece.cell_width - cells) ' ');
          loop cells rest
      | piece :: rest ->
          Buffer.add_substring buffer text piece.start_offset
            (piece.end_offset - piece.start_offset);
          loop dropped rest
    in
    loop 0 pieces;
    Buffer.contents buffer

(* Keep the first [cells] display cells: the counterpart to [drop_cells], so a
   caller cutting a row in two gets back exactly the cells it started with. A
   wide grapheme straddling the boundary is dropped whole here and padded with
   spaces there, so the two halves still add up to the whole.

   [split_cells] is not this function. It wraps, and a wrapper has to move
   forward or it never ends: it takes one piece even when [max_cells] is zero.
   Read as a prefix that invents a cell, which is how a row with no mark to
   colour drew its first character twice. *)
let take_cells text cells =
  let prefix, _, _ = cell_prefix text (max 0 cells) in
  prefix

(* The longest prefix that fits in [cells] without cutting a grapheme, and
   what is left of the text. Where {!take_cells} cuts by cells and gives up a
   wide grapheme that straddles the boundary -- padding its cells so the
   columns to the right stay put -- this one moves that grapheme to the tail
   and keeps every character. One is for a fixed column, the other for
   wrapping, where nothing may be lost.

   Escapes are carried into the prefix: they set a style, cost no cells, and
   the text after them opens under it. A prefix can therefore come back empty
   of visible cells and non-empty of bytes; the caller reads the tail to know
   whether it moved. *)
let split_at_cells text cells =
  if cells <= 0 then ("", text)
  else
    let rec walk used cut = function
      | [] -> cut
      | piece :: rest ->
          if piece.ansi then walk used piece.end_offset rest
          else if used + piece.cell_width <= cells then
            walk (used + piece.cell_width) piece.end_offset rest
          else cut
    in
    let cut = walk 0 0 (display_pieces text) in
    (String.sub text 0 cut, String.sub text cut (String.length text - cut))

let fit_width text width =
  if width <= 0 then ""
  else
    let pieces = display_pieces text in
    let cells = pieces_width pieces in
    if cells > width then
      let prefix, prefix_cells, saw_ansi =
        cell_prefix_of_pieces text pieces (width - 1)
      in
      let reset = if saw_ansi then "\x1B[0m" else "" in
      prefix ^ reset ^ String.make (width - 1 - prefix_cells) ' ' ^ "~"
    else text ^ String.make (width - cells) ' '

(* Where a bare URL begins and where it stops. Two readers ask -- the one that
   underlines them and the one that names what they point at -- and they get
   one answer, since a URL ending in one place for the underline and another
   for the name would underline text the name had not read. *)
let url_ends_at ch =
  match ch with
  | ' ' | '\t' | '\x1b' | '"' | '\'' | ')' | ']' | '>' | '<' -> true
  | _ -> Char.code ch < 0x20

let url_begins_at text index =
  let begins prefix =
    let plen = String.length prefix in
    index + plen <= String.length text
    && String.equal (String.sub text index plen) prefix
  in
  begins "http://" || begins "https://"

let url_end text index =
  let length = String.length text in
  let rec go i = if i < length && not (url_ends_at text.[i]) then go (i + 1) else i in
  go index

let bare_urls text =
  let length = String.length text in
  let rec loop index found =
    if index >= length then List.rev found
    else if url_begins_at text index then
      let stop = url_end text index in
      loop stop (String.sub text index (stop - index) :: found)
    else loop (index + 1) found
  in
  loop 0 []

let dress_bare_links ~open_style ~close_style text =
  let length = String.length text in
  let buffer = Buffer.create (length + 16) in
  let rec loop index =
    if index >= length then ()
    else if url_begins_at text index then begin
      let stop = url_end text index in
      Buffer.add_string buffer open_style;
      Buffer.add_string buffer (String.sub text index (stop - index));
      Buffer.add_string buffer close_style;
      loop stop
    end
    else begin
      Buffer.add_char buffer text.[index];
      loop (index + 1)
    end
  in
  loop 0;
  Buffer.contents buffer

let composer_max_rows = 5

let composer_lines ~max_rows input =
  let max_rows = max 1 max_rows in
  let lines = String.split_on_char '\n' input in
  let drop = max 0 (List.length lines - max_rows) in
  List.filteri (fun index _ -> index >= drop) lines

let input_viewport ~max_cells input =
  let max_cells = max 0 max_cells in
  let pieces = display_pieces input in
  if pieces_width pieces <= max_cells then input
  else if max_cells = 0 then ""
  else "~" ^ cell_suffix_of_pieces input pieces (max_cells - 1)

(* The chat pane draws the composer's first line with this prefix and wraps
   continuation lines to the same width, so the caret column is measured from
   the prefix the pane actually renders — not from a hand-copied constant that
   drifts the moment the prefix changes. *)
let chat_input_prompt_prefix = "  > "

let chat_input_prompt_cells = display_width chat_input_prompt_prefix

(* The pane draws its rows inside the box, which spends its border and the
   space after it before any content starts. *)
let chat_input_box_cells = 2

(* One authority for the rows that never belong to message history: box top,
   navigation header, operational identity header, header divider, input
   divider, composer, box bottom, and footer. Rendering and PgUp/PgDn must
   subtract the same number or a page skips one transcript row. *)
let message_fixed_chrome_rows = 8

let message_history_height ~terminal_rows ~status_rows =
  max 0 (terminal_rows - message_fixed_chrome_rows - max 0 status_rows)

let chat_title_row ~inner_cells ~title ~mode_suffix =
  let inner_cells = max 0 inner_cells in
  let mode_cells = display_width mode_suffix in
  if mode_cells >= inner_cells then fit_width mode_suffix inner_cells
  else fit_width title (inner_cells - mode_cells) ^ mode_suffix

(* At the newest row the arrows answer the composer's history. Once PgUp has
   moved into the transcript they adjust it one row at a time, so the hint can
   name them without risking a draft replacement. *)
let scroll_hint ~scrolled_back ~older_exist =
  if scrolled_back <= 0 then "PgUp:scroll back"
  else if older_exist then
    Printf.sprintf "\xe2\x86\x91/\xe2\x86\x93:line  PgUp/PgDn:page  Ctrl-E:newest  (%d back)"
      scrolled_back
  else
    (* At the oldest row with nothing more to fetch that is the more useful
       fact than the distance: an operator pressing up against a pane that will
       not move should know it is the start of the conversation rather than a
       stuck key, and at the start the distance says what "start" already
       says. Saying both is also what would have made this hint wider than the
       one it replaced. *)
    "\xe2\x86\x91/\xe2\x86\x93:line  PgUp/PgDn:page  Ctrl-E:newest  (start)"

let input_cursor_column ~terminal_cols ~input =
  let last_column = max 1 (terminal_cols - 1) in
  (* Three things sit left of the caret: the box, the prompt, and what was
     typed -- and the caret goes one cell past the last of them. Deriving this
     from the prompt alone put it on the prompt's own ">" instead of after the
     text, because the constant it replaced was all three added up rather than
     the prompt's width. *)
  min last_column
    (chat_input_box_cells + chat_input_prompt_cells + display_width input + 1)

(* Metadata rows read down the pane as a column: [timestamp] From [origin]
   request. Origins vary in width, so every label is padded to one badge and
   the request column stays put down the pane.

   The badge used to be 16 cells whatever the terminal was, so a
   [codex-mcp-client] read as [codex-mcp-clien…] on a 200-column screen with
   the room to spell it. The width is a fixed pane-derived budget, never below
   10 so the built-in activity labels remain legible, and
   never past 14: the built-in activity labels still read whole beside their
   marks, while an opaque long speaker name yields its middle instead of
   reserving empty cells on every body row. *)
let chat_role_label_column = 10

let chat_role_label_share = 10

(* A budget, not a measurement of what happens to be loaded.
   Measuring the widest label on the pane tied body width to the message
   list: [rows_of_entry] takes the body's width from what the badge leaves,
   so a differently-named speaker posting re-wrapped every body already on
   screen, changed how many rows the history occupies, and moved
   [msg_scroll] -- which counts rows back from the newest -- to a different
   part of the conversation. Labels on one live pane ran from 13 cells
   ("admin · agent") to 57
   ("keeper-canary-10t-cdx-sol-xhigh-r2-20260820-agent · agent"), so the
   badge took a quarter of the pane and gave it back one message later.
   Fixed, the body keeps its width and only a resize re-wraps. *)
let chat_role_label_budget = 14

let chat_role_label_width ~pane_cells =
  max chat_role_label_column
    (min chat_role_label_budget (pane_cells / chat_role_label_share))

(* Put the mark and label next to one another, then pad the column. The former
   right alignment made a short label look causally detached from its mark --
   [●                polisher] -- even though those cells carried no fact.
   An overrun still loses its head: these read [agent · surface] and share long
   prefixes, so the tail is what tells two of them apart. *)
let fit_name column label =
  let pieces = display_pieces label in
  let cells = pieces_width pieces in
  if cells > column then
    let kept = cell_suffix_of_pieces label pieces (column - 1) in
    let pad = max 0 (column - 1 - pieces_width (display_pieces kept)) in
    "…" ^ String.make pad ' ' ^ kept
  else label ^ String.make (column - cells) ' '

(* Keep both ends of [label] in [column] cells, dropping the middle.

   [fit_width] keeps the head and [fit_name] keeps the tail; an identifier
   needs both. Keeper names share long prefixes and differ in their tail --
   [fit_name] says so above -- but a name cut to its tail alone no longer says
   which family it came from. Cutting "rw-e0-r9-20260820-revision-audit" to
   "rw-e0-r9-20260820-revi~" loses exactly the part that distinguishes it,
   and to "…0820-revision-audit" loses exactly the part that groups it.

   The tail gets two thirds of the budget because it is the deciding end. As
   [column] shrinks the head's third reaches zero and this degrades into
   [fit_name]'s shape, which is the right thing to lose last.

   Left-aligned and padded to [column], so this is a drop-in where
   [fit_width] was cutting identifiers. *)
let fit_middle column label =
  if column <= 0 then ""
  else
    let pieces = display_pieces label in
    let cells = pieces_width pieces in
    if cells <= column then label ^ String.make (column - cells) ' '
    else if column = 1 then "…"
    else
      let usable = column - 1 in
      let head_cells = usable / 3 in
      let tail_cells = usable - head_cells in
      let head, head_width, saw_ansi =
        cell_prefix_of_pieces label pieces head_cells
      in
      let tail = cell_suffix_of_pieces label pieces tail_cells in
      let tail_width = pieces_width (display_pieces tail) in
      let reset = if saw_ansi then "\x1B[0m" else "" in
      let used = head_width + 1 + tail_width in
      head ^ reset ^ "…" ^ tail ^ String.make (max 0 (column - used)) ' '

(* One glyph per speaker, from the vocabulary the Keepers roster and Acting
   already use. Colour carries this distinction better, and NO_COLOR takes
   colour away, so the mark is what still answers "who said this" on a pane
   with no colour at all. *)
let speaker_mark : style -> string = function
  | User -> "\xe2\x96\xb6"      (* the operator sends *)
  | Inbound -> "\xe2\x97\x80"   (* someone else sent this here *)
  | Keeper -> "\xe2\x97\x8f"    (* a keeper speaks *)
  | Status -> "?"
  | Journal -> "\xe2\x97\x88"   (* the parallel Memory journal lane *)
  | Error -> "\xe2\x9c\x97"
  | Tool -> "\xe2\x96\xa0"
  | Skill Skill_live -> "\xe2\x97\x87"
  | Skill Skill_used -> "\xe2\x97\x86"
  | Skill Skill_attention -> "\xe2\x96\xb3"
  | Skill Skill_failure -> "\xe2\x9c\x97"
  | Thinking -> "\xc2\xb7"

(* Cells the speaker mark and its separator occupy at the head of a label, or
   zero when the column was too narrow to keep the mark at all. One reader, so
   the renderer that styles the mark and the layout that lays it out cannot
   disagree about where it ends. *)
let role_label_mark_cells ?(column = chat_role_label_column) ~style () =
  let column = max 1 column in
  let cells = display_width (speaker_mark style) + 1 in
  if column - cells < 1 then 0 else cells

let align_role_label ?(column = chat_role_label_column) ~style label =
  let column = max 1 column in
  let mark = speaker_mark style in
  (* The mark is paid for out of the badge, not added beside it: the body's
     width is taken from what the badge leaves, so charging it to the label
     keeps every body exactly as wide as it was.

     It is also kept outside the truncation. A label that overruns loses its
     head, and the mark sits at the head -- inside, the longest names would be
     the ones that lost the glyph, and those are the names a reader most needs
     help telling apart. *)
  let mark_cells = display_width mark + 1 in
  let inner = column - mark_cells in
  (* Kept in step with [role_label_mark_cells]: both decide on [inner < 1]. *)
  if inner < 1 then
    (* A pane too narrow to hold both keeps the name. Losing track of who is
       talking costs more than losing the shorthand for it. *)
    fit_name column label
  else mark ^ " " ^ fit_name inner label

(* The inverse of {!align_role_label}: the mark, the name, and the trailing
   column padding. Written here because this is where the three are joined, and a
   renderer taking them apart by measuring again is how the two drift.

   The renderer draws the name in reverse video. Reversing the aligned label
   whole painted the alignment as though it were the badge, so "AUTO" -- four
   letters -- arrived as an eighteen-cell inverted block with a dozen cells of
   highlighted nothing between the glyph and the name.

   Tolerant of a label that carries no mark: {!align_role_label} drops it on a
   column too narrow to hold both, and that label is all name. *)
let split_aligned_role_label ~style label =
  let mark = speaker_mark style in
  let prefix = mark ^ " " in
  let after_mark =
    if String.starts_with ~prefix label then
      String.sub label (String.length prefix)
        (String.length label - String.length prefix)
    else label
  in
  let mark = if String.equal after_mark label then "" else prefix in
  let rec walk index =
    if index > 0 && Char.equal after_mark.[index - 1] ' ' then walk (index - 1)
    else index
  in
  let boundary = walk (String.length after_mark) in
  ( mark
  , String.sub after_mark 0 boundary
  , String.sub after_mark boundary (String.length after_mark - boundary) )

let message_viewport_supported ~terminal_rows ~terminal_cols ~status_rows =
  (* At thirteen columns the frame leaves nine content cells: two for the
     body indent, four for the body itself, and three for a shortened source
     such as […aa]. Eleven columns left one source cell, which could draw only
     the omission marker and therefore admitted a chat pane with no identity. *)
  (* The fixed chrome costs eight rows. The title and operational identity use
     separate rows so a provider id cannot cut the title or context reading.
     Three history rows are the minimum that
     can show an oversized entry's identity/opening, an omission marker, and
     its latest output instead of silently dropping one of those facts. *)
  terminal_cols >= 13
  && message_history_height ~terminal_rows ~status_rows >= 3

let take_last count values =
  let drop = max 0 (List.length values - max 0 count) in
  values |> List.filteri (fun index _ -> index >= drop)

let split_cells ~max_cells text =
  if String.equal text "" then [ "" ]
  else
    let rec loop chunk_start chunk_end used_cells rows = function
      | [] ->
          let chunk = String.sub text chunk_start (chunk_end - chunk_start) in
          List.rev (chunk :: rows)
      | piece :: rest
        when piece.ansi || used_cells = 0
             || used_cells + piece.cell_width <= max_cells ->
          loop chunk_start piece.end_offset
            (used_cells + piece.cell_width) rows rest
      | piece :: rest ->
          let chunk = String.sub text chunk_start (chunk_end - chunk_start) in
          loop piece.start_offset piece.end_offset piece.cell_width
            (chunk :: rows) rest
    in
    loop 0 0 0 [] (display_pieces text)

(* A row is built by adding each word's own width to the row so far. That
   holds while no escape is left open across the join: an escape missing its
   final byte swallows the space after it, so the row and its parts disagree
   (pinned in the layout tests). A row carrying an escape therefore measures
   itself whole, the way this used to for every word of every row -- which
   made a row cost grow with the square of the words in it. *)
let wrap_words ~max_cells text =
  let max_cells = max 1 max_cells in
  let current = Buffer.create 128 in
  let current_cells = ref 0 in
  let current_holds_escape = ref false in
  let holds_escape word = String.contains word '\x1B' in
  let take_row () =
    let row = Buffer.contents current in
    Buffer.clear current;
    current_cells := 0;
    current_holds_escape := false;
    row
  in
  let rec loop rows = function
    | [] ->
        let rows =
          if Buffer.length current = 0 then rows else take_row () :: rows
        in
        List.rev rows
    | word :: rest as words ->
        let addition = if Buffer.length current = 0 then word else " " ^ word in
        let candidate_cells =
          if !current_holds_escape then
            display_width (Buffer.contents current ^ addition)
          else !current_cells + display_width addition
        in
        if candidate_cells <= max_cells then begin
          Buffer.add_string current addition;
          current_cells := candidate_cells;
          if holds_escape word then current_holds_escape := true;
          loop rows rest
        end
        else if Buffer.length current > 0 then loop (take_row () :: rows) words
        else
          let chunks = split_cells ~max_cells word in
          (match List.rev chunks with
           | [] -> loop rows rest
           | last :: reversed_completed ->
               let completed = List.rev reversed_completed in
               let rows =
                 List.fold_left (fun rows chunk -> chunk :: rows) rows completed
               in
               Buffer.add_string current last;
               current_cells := display_width last;
               current_holds_escape := holds_escape last;
               loop rows rest)
  in
  loop [] (String.split_on_char ' ' text)

(* Consecutive messages from one speaker share a heading. Repeating
   "[time] speaker request" on each of them spent a row per message saying who
   was talking, and a keeper answering in four parts said it four times.

   What a continuation keeps depends on what changed. A different moment is
   worth a row -- it says the pause between two things the same keeper said --
   but repeating an empty origin badge would look like an unnamed source, so
   that continuation carries only its timestamp. Two messages stamped the
   same second have nothing left to say, so they get no heading and read as
   the one message they look like. *)
let continues_previous ~(previous : entry option) (entry : entry) =
  match previous with
  | None -> false
  | Some previous ->
      previous.style = entry.style
      && String.equal previous.role_label entry.role_label
      && String.equal previous.request_label entry.request_label

let metadata_row ~(previous : entry option) ~inner_width (entry : entry) =
  let metadata =
    if not (continues_previous ~previous entry) then
      Some
        ( Origin
            { timestamp = entry.timestamp;
              role_label = entry.role_label;
              request_label = entry.request_label;
            }
        , Printf.sprintf "[%s] From [%s] %s" entry.timestamp entry.role_label
            entry.request_label )
    else
      match previous with
      | Some previous when String.equal previous.timestamp entry.timestamp -> None
      | Some _ | None ->
          Some
            ( Continued_at { timestamp = entry.timestamp }
            , Printf.sprintf "[%s]" entry.timestamp )
  in
  match metadata with
  | None -> None
  | Some (metadata, text) ->
    let fitted, _, _ = cell_prefix text inner_width in
    Some
      { style = entry.style
      ; kind = Metadata metadata
      ; shade = Shade_none
      ; text = fitted
      ; gutter_label_at = 0
      ; gutter = ""
      }

let same_timeline_bucket left right =
  Int.equal left.tb_year right.tb_year
  && Int.equal left.tb_month right.tb_month
  && Int.equal left.tb_day right.tb_day
  && Int.equal left.tb_hour right.tb_hour
  && Bool.equal left.tb_is_dst right.tb_is_dst

let timeline_break_row ~(previous : entry option) ~inner_width (entry : entry) =
  match entry.timeline_bucket with
  | None -> None
  | Some bucket
    when Option.exists
           (fun (previous : entry) ->
             Option.exists (same_timeline_bucket bucket)
               previous.timeline_bucket)
           previous ->
      None
  | Some bucket ->
      let label =
        Printf.sprintf "%04d-%02d-%02d \xc2\xb7 %02d:00" bucket.tb_year
          bucket.tb_month bucket.tb_day bucket.tb_hour
        ^ (if bucket.tb_is_dst then " DST" else "")
      in
      let lead = "\xe2\x94\x80\xe2\x94\x80 " ^ label ^ " " in
      let rule_cells = max 0 (inner_width - display_width lead) in
      let rule =
        String.concat ""
          (List.init rule_cells (fun _ -> "\xe2\x94\x80"))
      in
      let text, _, _ = cell_prefix (lead ^ rule) inner_width in
      Some
        { style = entry.style
        ; kind = Metadata (Timeline_break bucket)
        ; shade = Shade_none
        ; text
        ; gutter_label_at = 0
        ; gutter = ""
        }

(* A body is a document, not a row. [sanitize] is applied to each line rather
   than to the whole, because escaping a newline the way a terminal escape is
   escaped turns the document into one unbroken run with the escape printed
   where each break belonged. Per line the escape still covers what it is there
   for -- a line cannot carry a control sequence into the terminal -- and the
   breaks the author wrote survive. A line that wraps to nothing is a blank
   line: a paragraph break, not an absence. The caller supplies [sanitize] so
   this module keeps no terminal vocabulary of its own. *)
let wrap_body ?markdown ~max_cells ~sanitize text =
  let safe_lines = text |> String.split_on_char '\n' |> List.map sanitize in
  match markdown with
  | Some render ->
    (* Rendering happens after the escaping, not before: markdown is written in
       printable ASCII, so escaping a control byte first takes nothing the
       renderer reads, and the renderer never sees a byte that could reach the
       terminal as a sequence. It owns the wrapping from there -- fenced code
       keeps its own breaks, which a word wrap would ruin. *)
    render ~width:max_cells (String.concat "\n" safe_lines)
  | None ->
    List.concat_map
      (fun line ->
         match wrap_words ~max_cells line with [] -> [ "" ] | rows -> rows)
      safe_lines

(* What a body keeps whatever else wants the width. Four cells is what
   [rows_of_entry] has always floored it at. *)
let min_body_cells = 4

(* [HH:MM:SS] cut to the minute for the inline margin. Seconds earn their
   width on a row of their own; in a margin they are paid for once per message.
   Text that is not a clock of that shape is left as it is rather than cut
   blind. *)
(* Every row's clock takes the same cells. A settled row says "23:38" and the
   streaming turn says "live", and the gutter's width is what the body's width
   is taken from, so one cell of difference wrapped the live body differently
   from the rows it was about to join. *)
let chat_clock_column = 5

let pad_clock text =
  let cells = display_width text in
  if cells >= chat_clock_column then text
  else String.make (chat_clock_column - cells) ' ' ^ text

let short_clock timestamp =
  if
    String.length timestamp = 8
    && Char.equal timestamp.[2] ':'
    && Char.equal timestamp.[5] ':'
  then String.sub timestamp 0 5
  else timestamp

(* [Origin_row] leaves the origin on a row of its own. The other two fold it
   into the body's left margin, which buys back a row per message -- eight
   speakers taking turns spent eight of a forty-row pane saying who was
   talking.

   Every row of the pane keeps the same margin width: the label arrives padded
   to one column, so a continuation indents to where the first row started and
   the body still reads as a block. [Origin_bare] drops the clock and keeps
   the speaker, never the other way round -- losing track of who is talking
   costs more than losing track of when. *)
(* A continuation keeps its own speaker's mark, drawn in the quiet tone the
   renderer gives the whole gutter here.

   It used to borrow [Thinking]'s dot, on the argument that reusing a glyph
   keeps the column's alphabet closed. It did the opposite: the dot then meant
   two things, and a second AUTO message in the same second read as a block of
   reasoning -- same glyph, same grey, no name, because a continuation drops
   the name as well. The alphabet is closed when each mark means one thing.
   Bright against quiet is what separates a new speaker from the same one
   still talking, and a Thinking continuation still draws a dot because that
   is what it is. *)
let continued_mark style = speaker_mark style

(* A tool's output and a recalled memory arrive as text the Keeper did not
   write, so they are quoted rather than said. Everything else the pane draws
   is either the Keeper talking or the operator talking, and that is prose.

   Reasoning is the Keeper's own, not a quotation, however folded it is. *)
let shade_of_style : style -> shade = function
  | Tool | Skill _ | Status | Journal -> Shade_quoted
  | User | Inbound | Keeper | Error | Thinking -> Shade_none

let origin_gutter ~origin ~previous ~inner_width entry =
  match origin with
  | Origin_row -> None
  | Origin_inline | Origin_bare ->
      let clock =
        match origin with
        | Origin_inline -> pad_clock (short_clock entry.timestamp) ^ " "
        | Origin_row | Origin_bare -> ""
      in
      (* The margin is taken from the body, so it cannot be wider than what
         the body can spare. Left unbounded, one long keeper name on a narrow
         pane drew a margin wider than the frame it sits in and the row
         spilled past its own border. [min_body_cells] is what
         {!rows_of_entry} floors the body at; the margin gets whatever is
         left, and on a pane with nothing left it gets nothing rather than
         pushing the messages out. *)
      let ceiling = max 0 (inner_width - 2 - min_body_cells) in
      let role_cells = display_width entry.role_label in
      let role_fits = role_cells <= ceiling in
      let label, mark_cells =
        if role_fits then
          ( entry.role_label
          , min role_cells (max 0 entry.role_label_mark_cells) )
        else
          (* [role_label_mark_cells] is the producer's typed boundary between
             the speaker mark and the source. Once the whole aligned label no
             longer fits, omit that mark and spend every gutter cell on the
             source after it. Reusing the old boundary after [fit_middle]
             would colour an ellipsis or source byte as though it were a mark. *)
          let source =
            drop_cells entry.role_label
              (min role_cells (max 0 entry.role_label_mark_cells))
          in
          fit_middle ceiling source, 0
      in
      (* Only a complete aligned label earns a clock. A shortened source uses
         the whole ceiling; at normal width both pieces still return exactly
         [clock ^ entry.role_label], byte for byte. *)
      let clock_cells =
        if role_fits then
          min (display_width clock)
            (max 0 (ceiling - display_width label))
        else 0
      in
      (* A partial clock is context, not an identifier. [fit_width] would put
         its generic "~" over the final clock cell, producing gutters such as
         [12:~keeper] that look like damaged chat. Keep the cell-safe prefix
         and its alignment without inventing a truncation glyph. *)
      let clock = take_cells clock clock_cells in
      let clock =
        clock ^ String.make (max 0 (clock_cells - display_width clock)) ' '
      in
      let filled = clock ^ label in
      (* Where the kind label starts: past the clock and past the speaker mark.
         Computed here because this is where the clock is prepended; a renderer
         deriving it would be measuring the same two things a second time.
         [mark_cells] is zero for a shortened source, because that row no
         longer contains the mark the original boundary described. *)
      let label_at = clock_cells + mark_cells in

      if continues_previous ~previous entry then
        (* Padded rather than repeated: a second row from the same speaker in
           the same second has nothing new to say, and [fit_width] measures the
           cells a label actually occupies where [String.make] would count its
           bytes. *)
        (* The clock stays. A continuation says the same speaker is still
           talking, not that time stopped: the gap between two things one
           Keeper said is exactly what a reader checks here, and blanking the
           whole margin took it away along with the name.

           The name is what goes, since repeating it says nothing, and the mark
           drops to the quietest glyph so a row that continues reads as lower
           than the row that started. What is left is the speaker column doing
           the telling -- a name appears only where the speaker changes. *)
        (* No label to hold back on a row that draws no name. *)
        let continued = clock ^ continued_mark entry.style ^ " " in
        Some (fit_width continued (display_width filled), 0)
      else Some (filled, label_at)

let rows_of_entry ?markdown ?(origin = Origin_row) ~inner_width ~previous entry =
  let gutter = origin_gutter ~origin ~previous ~inner_width entry in
  let gutter_width =
    match gutter with None -> 0 | Some (text, _) -> display_width text
  in
  let body_width = max min_body_cells (inner_width - 2 - gutter_width) in
  (* Keepers write markdown. Rendering it is the caller's to supply, so this
     module keeps no terminal vocabulary; without it the body is wrapped as the
     plain text it always was. *)
  let body_chunks =
    match markdown with
    | Some render -> render ~entry ~width:body_width
    | None ->
        entry.body |> String.split_on_char '\n'
        |> List.concat_map (split_cells ~max_cells:body_width)
  in
  let body_chunks =
    let rec drop_empty = function
      | chunk :: rest when String.trim chunk = "" -> drop_empty rest
      | reversed -> List.rev reversed
    in
    match drop_empty (List.rev body_chunks) with
    | [] -> [ "" ]
    | chunks -> chunks
  in
  let body_rows =
    let margin, label_at = Option.value gutter ~default:("", 0) in
    let blank = fit_width "" (display_width margin) in
    body_chunks
    |> List.mapi (fun index chunk ->
      { style = entry.style
      ; kind = Body
      ; shade = shade_of_style entry.style
      ; text = "  " ^ chunk
      ; gutter_label_at = (if index = 0 then label_at else 0)
      ; gutter = (if index = 0 then margin else blank)
      })
  in
  let message_rows =
    match origin with
    | Origin_inline | Origin_bare -> body_rows
    | Origin_row -> (
        match metadata_row ~previous ~inner_width entry with
        | None -> body_rows
        | Some metadata -> metadata :: body_rows)
  in
  match timeline_break_row ~previous ~inner_width entry with
  | None -> message_rows
  | Some timeline_break -> timeline_break :: message_rows

let viewport_gap_text ~inner_width hidden_rows =
  let candidates =
    [ Printf.sprintf
        "  \xe2\x8b\xaf %d chat rows hidden \xc2\xb7 PgUp to reveal"
        hidden_rows
    ; Printf.sprintf "  \xe2\x8b\xaf %d hidden \xc2\xb7 PgUp" hidden_rows
    ; Printf.sprintf "  \xe2\x8b\xaf %d hidden" hidden_rows
    ; Printf.sprintf "\xe2\x8b\xaf%d" hidden_rows
    ; "\xe2\x8b\xaf"
    ]
  in
  Option.value
    (List.find_opt (fun text -> display_width text <= inner_width) candidates)
    ~default:""

(* At the live edge, keep enough of an oversized newest entry to identify it,
   see its opening when space permits, and see its latest output. The typed gap
   makes the missing middle explicit; without it, inline mode looked like one
   continuous message even though rows had disappeared. *)
let newest_entry_window ~inner_width ~height rows =
  (* A civil-hour rail is context, while the origin and latest body are the
     message. If all of them do not fit at the live edge, lay out the message
     first and count the rail among the explicitly hidden physical rows. The
     transcript itself is unchanged, so ordinary scrollback reaches the rail. *)
  let hidden_timeline_rows, rows =
    match rows with
    | { kind = Metadata (Timeline_break _); _ } :: rest
      when List.length rows > height ->
        1, rest
    | _ -> 0, rows
  in
  match height, rows with
  | 0, _ | _, [] -> []
  | 1, first :: _ -> [ first ]
  | 2, first :: rest -> (
      match List.rev rest with [] -> [ first ] | latest :: _ -> [ first; latest ])
  | _, first :: rest ->
      let start, rest =
        match first.kind, rest with
        | Metadata _, body :: rest when height >= 4 -> [ first; body ], rest
        | (Metadata _ | Body | Viewport_gap _), _ -> [ first ], rest
      in
      let tail = take_last (height - 1 - List.length start) rest in
      let hidden_rows =
        List.length rows - List.length start - List.length tail
        + hidden_timeline_rows
      in
      let gap =
        { style = Status
        ; kind = Viewport_gap { hidden_rows }
        ; shade = Shade_none
        ; text = viewport_gap_text ~inner_width hidden_rows
        ; gutter_label_at = 0
        ; gutter = ""
        }
      in
      start @ (gap :: tail)

let visible_rows ?markdown ?origin ~inner_width ~height entries =
  let inner_width = max 1 inner_width in
  let height = max 0 height in
  let rec collect remaining selected = function
    | [] -> selected
    | _ when remaining = 0 -> selected
    | entry :: older ->
        let rows =
          rows_of_entry ?markdown ?origin ~inner_width
            ~previous:(List.nth_opt older 0) entry
        in
        let chosen =
          if List.length rows <= remaining then rows
          else if selected = [] then
            newest_entry_window ~inner_width ~height:remaining rows
          else take_last remaining rows
        in
        collect (remaining - List.length chosen) (chosen @ selected) older
  in
  collect height [] (List.rev entries)

let total_rows ?markdown ?origin ?previous ~inner_width entries =
  let inner_width = max 1 inner_width in
  List.fold_left
    (fun (previous, total) entry ->
       ( Some entry
       , total
         + List.length (rows_of_entry ?markdown ?origin ~inner_width ~previous entry) ))
    (previous, 0) entries
  |> snd

let max_scroll ?markdown ?origin ~inner_width ~height entries =
  max 0 (total_rows ?markdown ?origin ~inner_width entries - max 1 height)

(* Nothing older than the newest [from_bottom + height] rows can reach the
   window, so the walk stops once it holds them. Laying out the whole
   transcript to slice a screenful out of the end made every scrolled frame
   cost what the conversation had accumulated. *)
let scrolled_rows ?markdown ?origin ~inner_width ~height ~from_bottom entries =
  if from_bottom <= 0 then visible_rows ?markdown ?origin ~inner_width ~height entries
  else begin
    let inner_width = max 1 inner_width in
    let height = max 0 height in
    let wanted = from_bottom + height in
    let rec collect gathered gathered_count = function
      | [] -> gathered, gathered_count
      | _ when gathered_count >= wanted -> gathered, gathered_count
      | entry :: older ->
          let rows =
            rows_of_entry ?markdown ?origin ~inner_width
              ~previous:(List.nth_opt older 0) entry
          in
          collect (rows @ gathered) (gathered_count + List.length rows) older
    in
    let newest, newest_count = collect [] 0 (List.rev entries) in
    let bottom = max 0 (newest_count - from_bottom) in
    let first = max 0 (bottom - height) in
    List.filteri (fun index _ -> index >= first && index < bottom) newest
  end

(* A clamp needs the row count only up to where the answer stops moving: once
   [requested + height] rows exist the limit is at least [requested], and what
   lies further back cannot change the result. Reaching that through
   {!max_scroll} counted the whole transcript on every frame, including the
   frames where nobody had scrolled at all. *)
let clamp_scroll ?markdown ?origin ~inner_width ~height requested entries =
  if requested <= 0 then requested
  else begin
    let inner_width = max 1 inner_width in
    (* {!max_scroll} measures against at least one row, and this has to answer
       the same as it does. *)
    let height = max 1 height in
    let enough = requested + height in
    let rec count total = function
      | [] -> total
      | _ when total >= enough -> total
      | entry :: older ->
          count
            (total
             + List.length
                 (rows_of_entry ?markdown ?origin ~inner_width
                    ~previous:(List.nth_opt older 0) entry))
            older
    in
    min requested (max 0 (count 0 (List.rev entries) - height))
  end

(* Clamp and slice from the rows one walk already measured. The separate
   [clamp_scroll] then [scrolled_rows] calls traverse the same newest prefix;
   with a bounded render cache, a prefix larger than the cache can evict its
   own later hits during the second traversal. Keeping the rows from this walk
   avoids a frame-local cache of another size and makes every visited entry
   pay for layout once. *)
let clamped_scrolled_rows ?markdown ?origin ~inner_width ~height ~requested entries =
  if requested <= 0 then
    requested, visible_rows ?markdown ?origin ~inner_width ~height entries
  else begin
    let inner_width = max 1 inner_width in
    let window_height = max 0 height in
    let bound_height = max 1 height in
    let enough = requested + bound_height in
    let rec collect gathered gathered_count = function
      | [] -> gathered, gathered_count
      | _ when gathered_count >= enough -> gathered, gathered_count
      | entry :: older ->
          let rows =
            rows_of_entry ?markdown ?origin ~inner_width
              ~previous:(List.nth_opt older 0) entry
          in
          collect (rows @ gathered) (gathered_count + List.length rows) older
    in
    let gathered, gathered_count = collect [] 0 (List.rev entries) in
    let from_bottom =
      min requested (max 0 (gathered_count - bound_height))
    in
    let bottom = max 0 (gathered_count - from_bottom) in
    let first = max 0 (bottom - window_height) in
    ( from_bottom
    , List.filteri
        (fun index _ -> index >= first && index < bottom)
        gathered )
  end

let last_page_start ~height row_costs =
  let costs = Array.of_list row_costs in
  let count = Array.length costs in
  if count = 0 then 0
  else begin
    let height = max 1 height in
    let rec walk index used =
      if index < 0 then 0
      else
        (* A row is the least an item can cost; a zero would let the walk
           claim the whole list fits in any height. *)
        let cost = max 1 costs.(index) in
        if used + cost > height then index + 1 else walk (index - 1) (used + cost)
    in
    min (count - 1) (walk (count - 1) 0)
  end

(* One span, in the largest unit that still carries a remainder. Every reading
   is at most seven cells wide, so a column sized for the longest span holds
   every shorter one.

   The tiers stopped at minutes here, and the Fusion table drew its ages
   through this: all 28 rows read [12045m~], five figures of minutes cut by
   the column. A day-old run and a nine-day-old run were the same shape. The
   comment beside the Gate row that prompted the hour tier says what applies
   just as well here -- an operator weighs the number, and five figures is
   arithmetic homework, not a weight.

   Two callers spell a span this way and they used to hold separate ladders
   with separate ceilings: this one stopped at minutes, [duration_text]
   stopped at hours. They differ in what a span from the future means, which
   is theirs to decide, not in how a span reads. *)
let span_text seconds =
  let whole = int_of_float (Float.max 0. seconds) in
  if whole < 60 then Printf.sprintf "%ds" whole
  else if whole < 3600 then Printf.sprintf "%dm%02ds" (whole / 60) (whole mod 60)
  else if whole < 86_400 then
    Printf.sprintf "%dh%02dm" (whole / 3600) (whole mod 3600 / 60)
  else Printf.sprintf "%dd%02dh" (whole / 86_400) (whole mod 86_400 / 3600)

let age_text ~now ~since =
  let seconds = now -. since in
  (* A clock that moved backwards says nothing rather than a negative age. The
     row that shows this has no way to draw "-4s" a reader could use. *)
  if seconds < 0. then None else Some (span_text seconds)
