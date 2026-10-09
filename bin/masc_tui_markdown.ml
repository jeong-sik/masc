module Layout = Masc_tui_message_layout

type span = string * string

type palette = {
  strong : span;
  emphasis : span;
  strike : span;
  code : span;
  heading : int -> span;
  quote : span;
  link_text : span;
  link_target : span;
  rule : span;
  bullet : string;
  code_gutter : string;
  code_header : span;
  code_border : span;
  quote_gutter : string;
  table_header : span;
  table_gutter : string;
  (* What joins the rule row between columns. The gutter itself used to run
     through it, which drew the rule as separate dashes with a bar standing in
     the gap -- the one row whose job is to say where the columns divide was
     the row that broke there. It has to measure the same cells as the gutter
     or the rule stops lining up with the rows it belongs to. *)
  table_rule_gutter : string;
  (* Draw the outer box. Off unless the reader asked: every row gains an edge
     on each side and the block a top and a bottom, so the columns have four
     fewer cells to share. On a narrow pane that is a column of content spent
     saying where the content ends. *)
  table_frame : bool;
  (* Styles for fenced code that names a language this module lexes. A fence
     without a language, or one naming a language it does not, keeps the
     single [code] span: colouring a grammar nobody parsed is decoration
     pretending to be syntax. *)
  code_keyword : span;
  code_string : span;
  code_comment : span;
  code_number : span;
  code_diff_added : span;
      (** A ["```diff"] fence's added line. Whole-line, not token-shaped. *)
  code_diff_removed : span;  (** The same fence's removed line. *)
  code_type : span;
}

let plain_palette =
  { strong = ("", "")
  ; emphasis = ("", "")
  ; strike = ("", "")
  ; code = ("", "")
  ; heading = (fun _ -> ("", ""))
  ; quote = ("", "")
  ; link_text = ("", "")
  ; link_target = ("", "")
  ; rule = ("", "")
  ; bullet = "-"
  ; code_gutter = "| "
  ; code_header = ("", "")
  ; code_border = ("", "")
  ; quote_gutter = "> "
  ; table_header = ("", "")
  ; table_gutter = " | "
  ; table_rule_gutter = "\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80"
  ; table_frame = false
  ; code_keyword = ("", "")
  ; code_string = ("", "")
  ; code_comment = ("", "")
  ; code_number = ("", "")
  ; code_diff_added = ("", "")
  ; code_diff_removed = ("", "")
  ; code_type = ("", "")
  }

type streaming_render = {
  rows : string list;
  mutable_source_start : int;
  mutable_row_start : int;
}

(* {1 Inline markers} *)

let kind_plain = "plain"
let kind_strong = "strong"
let kind_emphasis = "emphasis"
let kind_strike = "strike"
let kind_code = Masc_tui_code_lexer.kind_code
let kind_link_text = "link_text"
let kind_link_target = "link_target"
(* Fenced-code token kinds live with the lexers in Masc_tui_code_lexer; the
   aliases keep every reference here reading as before. *)
let kind_code_keyword = Masc_tui_code_lexer.kind_keyword
let kind_code_string = Masc_tui_code_lexer.kind_string
let kind_code_comment = Masc_tui_code_lexer.kind_comment
let kind_code_number = Masc_tui_code_lexer.kind_number
let kind_code_type = Masc_tui_code_lexer.kind_type
let kind_code_diff_added = Masc_tui_code_lexer.kind_diff_added
let kind_code_diff_removed = Masc_tui_code_lexer.kind_diff_removed

let starts_at text index marker =
  let length = String.length marker in
  index + length <= String.length text
  && String.equal (String.sub text index length) marker

(* A marker only opens a span when its partner is on the same line. An
   unmatched [*] is a literal asterisk -- keepers write those -- and treating
   it as an opener would swallow the rest of the line. *)
let find_close text ~from ~marker =
  let length = String.length marker in
  let limit = String.length text in
  let rec scan index =
    if index + length > limit then None
    else if starts_at text index marker then Some index
    else scan (index + 1)
  in
  if from >= limit then None else scan from

let is_word_byte byte =
  (byte >= 'a' && byte <= 'z')
  || (byte >= 'A' && byte <= 'Z')
  || (byte >= '0' && byte <= '9')
  || Char.code byte >= 0x80

(* [_] does not mark emphasis inside a word. Half this workspace's chat is
   snake_case, and pairing the underscores in [keeper_tool_descriptor] ate them
   and italicised the middle. [*] keeps the permissive rule -- it is not a
   character identifiers are built from. *)
let underscore_opens text index =
  let before = if index = 0 then ' ' else text.[index - 1] in
  let after_index = index + 1 in
  let after =
    if after_index >= String.length text then ' ' else text.[after_index]
  in
  (not (is_word_byte before)) && after <> ' '

let underscore_closes text index =
  let before = if index = 0 then ' ' else text.[index - 1] in
  let after_index = index + 1 in
  let after =
    if after_index >= String.length text then ' ' else text.[after_index]
  in
  before <> ' ' && not (is_word_byte after)

let find_char text ~from char =
  match String.index_from_opt text from char with
  | Some index -> Some index
  | None -> None

let inline_segments_lexed ?on_segment text =
  let limit = String.length text in
  let out = ref [] in
  let pending = Buffer.create (String.length text) in
  let pending_positions = ref [] in
  let flush_pending () =
    if Buffer.length pending > 0 then begin
      let text = Buffer.contents pending in
      out := (text, kind_plain) :: !out;
      Option.iter (fun emit -> emit (Array.of_list (List.rev !pending_positions))) on_segment;
      pending_positions := [];
      Buffer.clear pending
    end
  in
  let emit ~positions body kind =
    if String.length body > 0 then begin
      flush_pending ();
      out := (body, kind) :: !out;
      Option.iter (fun emit -> emit (positions ())) on_segment
    end
  in
  let rec walk index =
    if index >= limit then ()
    else
      let literal () =
        Buffer.add_char pending text.[index];
        Option.iter (fun _ -> pending_positions := Some index :: !pending_positions) on_segment;
        walk (index + 1)
      in
      let styled ?(closes = fun _ -> true) marker kind =
        let opening = index + String.length marker in
        let rec seek from =
          match find_close text ~from ~marker with
          | None -> None
          | Some closing ->
              if closes closing then Some closing
              else seek (closing + String.length marker)
        in
        match seek opening with
        | None -> literal ()
        | Some closing ->
            let body = String.sub text opening (closing - opening) in
            if String.trim body = "" then literal ()
            else begin
              emit ~positions:(fun () -> Array.init (String.length body) (fun i -> Some (opening + i))) body kind;
              walk (closing + String.length marker)
            end
      in
      match text.[index] with
      | '`' -> styled "`" kind_code
      | '*' when starts_at text index "**" -> styled "**" kind_strong
      | '_' when starts_at text index "__" ->
          if underscore_opens text index then
            styled ~closes:(fun close -> underscore_closes text (close + 1)) "__"
              kind_strong
          else literal ()
      (* [~~] only. A single [~] is a shell home directory and an
         approximation sign far more often than it is a marker, and treating
         it as one ate text nobody meant to strike. *)
      | '~' when starts_at text index "~~" -> styled "~~" kind_strike
      | '*' -> styled "*" kind_emphasis
      | '_' ->
          if underscore_opens text index then
            styled ~closes:(fun close -> underscore_closes text close) "_"
              kind_emphasis
          else literal ()
      | '[' -> (
          (* [label](target). Both halves are kept: a terminal cannot follow a
             link, so hiding the target loses the only usable half. The target
             keeps its parentheses and a separating space; colour is not a
             delimiter, and copied or NO_COLOR text must not collapse the two
             halves into [labeltarget]. *)
          match find_char text ~from:(index + 1) ']' with
          | Some close_label
            when starts_at text (close_label + 1) "(" -> (
              match find_char text ~from:(close_label + 2) ')' with
              | None -> literal ()
              | Some close_target ->
                  let label =
                    String.sub text (index + 1) (close_label - index - 1)
                  in
                  let target =
                    String.sub text (close_label + 2)
                      (close_target - close_label - 2)
                  in
                  emit ~positions:(fun () -> Array.init (String.length label)
                    (fun i -> Some (index + 1 + i))) label kind_link_text;
                  emit ~positions:(fun () -> Array.init (String.length target + 3)
                    (fun i -> if i = 0 then None else Some (close_label + i)))
                    (" (" ^ target ^ ")") kind_link_target;
                  walk (close_target + 1))
          | Some _ | None -> literal ())
      | _ -> literal ()
  in
  walk 0;
  flush_pending ();
  List.rev !out

let inline_segments_traced ?on_segment text =
  (* Plain comments need one segment, without a byte-by-byte lexer walk. *)
  if text = "" then []
  else if
    String.exists
      (function '`' | '*' | '_' | '~' | '[' -> true | _ -> false)
      text
  then inline_segments_lexed ?on_segment text
  else (
    Option.iter (fun emit -> emit (Array.init (String.length text) (fun i -> Some i))) on_segment;
    [ (text, kind_plain) ])

let inline_segments text = inline_segments_traced text

(* {1 Wrapping styled segments} *)

let span_of_palette palette kind =
  if String.equal kind kind_strong then palette.strong
  else if String.equal kind kind_emphasis then palette.emphasis
  else if String.equal kind kind_strike then palette.strike
  else if String.equal kind kind_code then palette.code
  else if String.equal kind kind_link_text then palette.link_text
  else if String.equal kind kind_link_target then palette.link_target
  else if String.equal kind kind_code_keyword then palette.code_keyword
  else if String.equal kind kind_code_string then palette.code_string
  else if String.equal kind kind_code_comment then palette.code_comment
  else if String.equal kind kind_code_number then palette.code_number
  else if String.equal kind kind_code_type then palette.code_type
  else if String.equal kind kind_code_diff_added then palette.code_diff_added
  else if String.equal kind kind_code_diff_removed then palette.code_diff_removed
  else ("", "")

type token = {
  word : string;
  kind : string;
  space_before : bool;
}

(* Words carry their styling, so a wrap inside a bold sentence reopens bold on
   the next row instead of ending it there. *)
let tokens_of_segments segments =
  let tokens = ref [] in
  List.iter
    (fun (text, kind) ->
       let pieces = String.split_on_char ' ' text in
       List.iteri
         (fun index piece ->
            let space_before = index > 0 in
            if String.length piece > 0 || space_before then
              tokens := { word = piece; kind; space_before } :: !tokens)
         pieces)
    segments;
  List.rev !tokens

let render_token palette token =
  let opening, closing = span_of_palette palette token.kind in
  if String.equal token.word "" then "" else opening ^ token.word ^ closing

type source_range = {
  start_byte : int;
  end_byte : int;
}

type mapped_row = {
  text : string;
  source_ranges : source_range list;
}

type inline_render = {
  semantic_text : string;
  source_positions : int option array;
  mapped_rows : mapped_row list;
}

(* Ranges refer to the inline semantic stream, before wrapping and styling.
   A separator dropped at a wrap retains its byte in that stream. Generated
   prefixes and ANSI styling never acquire a source range. *)
let wrap_tokens ?on_row palette ~width tokens =
  let width = max 1 width in
  let rows = ref [] in
  let current = Buffer.create 128 in
  let current_cells = ref 0 in
  let current_has_word = ref false in
  let source_byte = ref 0 in
  let ranges = ref [] in
  let record start_byte length =
    match on_row with
    | None -> ()
    | Some _ when length = 0 -> ()
    | Some _ -> ranges := {start_byte; end_byte=start_byte + length} :: !ranges
  in
  let flush () =
    let text = Buffer.contents current in
    rows := text :: !rows;
    Option.iter (fun emit -> emit {text; source_ranges=List.rev !ranges}) on_row;
    ranges := [];
    Buffer.clear current;
    current_cells := 0;
    current_has_word := false
  in
  let append token ~start_byte ~word_cells word =
    Buffer.add_string current (render_token palette { token with word });
    record start_byte (String.length word);
    current_cells := !current_cells + word_cells;
    if word <> "" then current_has_word := true
  in
  let append_word token ~start_byte ~word_cells =
    let remaining = width - !current_cells in
    if word_cells <= remaining then append token ~start_byte ~word_cells token.word
    else begin
      let prefix, tail = Layout.split_at_cells token.word remaining in
      if prefix <> "" then
        append token ~start_byte ~word_cells:(Layout.display_width prefix) prefix;
      (* Split the remaining word once at the full row width, preserving
         graphemes, source bytes and styling. *)
      let next_byte = ref (start_byte + String.length prefix) in
      List.iter (fun word ->
        if Buffer.length current > 0 then flush ();
        append token ~start_byte:!next_byte ~word_cells:(Layout.display_width word) word;
        next_byte := !next_byte + String.length word)
        (Layout.split_cells ~max_cells:width tail)
    end
  in
  List.iter (fun token ->
    let separator_cells = if token.space_before then 1 else 0 in
    let start_byte = !source_byte + separator_cells in
    let word_cells = Layout.display_width token.word in
    let wrapped = !current_has_word
      && !current_cells + separator_cells + word_cells > width in
    if wrapped then flush ();
    if token.space_before && not wrapped then (
      if !current_cells = width then flush ();
      Buffer.add_char current ' ';
      record !source_byte 1;
      incr current_cells);
    append_word token ~start_byte ~word_cells;
    source_byte := start_byte + String.length token.word) tokens;
  if Buffer.length current > 0 || !rows = [] then flush ();
  List.rev !rows

let render_inline_with_spans ~palette ~width ~prefix ~continuation text =
  let source_positions = ref [] in
  let segments = inline_segments_traced ~on_segment:(fun positions -> source_positions := positions :: !source_positions) text in
  let tokens = tokens_of_segments segments in
  let semantic = Buffer.create (String.length text) in
  List.iter (fun token ->
    if token.space_before then Buffer.add_char semantic ' ';
    Buffer.add_string semantic token.word) tokens;
  let mapped = ref [] in
  let body_width = max 1 (width - Layout.display_width prefix) in
  let (_ : string list) = wrap_tokens ~on_row:(fun row -> mapped := row :: !mapped)
    palette ~width:body_width tokens in
  let mapped_rows = List.rev !mapped |> List.mapi (fun index row ->
    {row with text=(if index = 0 then prefix else continuation) ^ row.text}) in
  {semantic_text=Buffer.contents semantic;
   source_positions=Array.concat (List.rev !source_positions); mapped_rows}

let wrap_inline palette ~width ~prefix ~continuation text =
  let prefix_cells = Layout.display_width prefix in
  let body_width = max 1 (width - prefix_cells) in
  let rows =
    wrap_tokens palette ~width:body_width (tokens_of_segments (inline_segments text))
  in
  List.mapi
    (fun index row -> (if index = 0 then prefix else continuation) ^ row)
    rows

(* {1 Blocks} *)

let fence_marker line =
  let trimmed = String.trim line in
  if starts_at trimmed 0 "```" then Some "```"
  else if starts_at trimmed 0 "~~~" then Some "~~~"
  else None

let non_colliding_fence_marker lines =
  let collides marker =
    List.exists
      (fun line -> Option.exists (String.equal marker) (fence_marker line))
      lines
  in
  if not (collides "```") then Some "```"
  else if not (collides "~~~") then Some "~~~"
  else None

let is_rule line =
  let trimmed = String.trim line in
  let distinct char =
    String.length trimmed >= 3 && String.for_all (fun c -> c = char) trimmed
  in
  distinct '-' || distinct '*' || distinct '_'

let trim_source_bounds text start stop =
  let whitespace = function ' ' | '\t' | '\n' | '\r' | '\012' -> true | _ -> false in
  let rec left at = if at < stop && whitespace text.[at] then left (at + 1) else at in
  let start = left start in
  let rec right at = if at > start && whitespace text.[at - 1] then right (at - 1) else at in
  start, right stop

let heading_level line =
  let rec count index =
    if index < String.length line && line.[index] = '#' then count (index + 1)
    else index
  in
  let level = count 0 in
  if level >= 1 && level <= 6 && level < String.length line
     && line.[level] = ' '
  then
    let start, stop = trim_source_bounds line level (String.length line) in
    Some (level, String.sub line start (stop - start), start)
  else None

let bullet_item line =
  let trimmed_left =
    let rec skip index =
      if index < String.length line && line.[index] = ' ' then skip (index + 1)
      else index
    in
    skip 0
  in
  let indent = trimmed_left in
  let rest = String.sub line indent (String.length line - indent) in
  if String.length rest >= 2
     && (rest.[0] = '-' || rest.[0] = '*' || rest.[0] = '+')
     && rest.[1] = ' '
  then Some (indent, String.sub rest 2 (String.length rest - 2), indent + 2)
  else None

let ordered_item line =
  let limit = String.length line in
  let rec digits index =
    if index < limit && line.[index] >= '0' && line.[index] <= '9' then
      digits (index + 1)
    else index
  in
  let indent =
    let rec skip index =
      if index < limit && line.[index] = ' ' then skip (index + 1) else index
    in
    skip 0
  in
  let after_digits = digits indent in
  if after_digits > indent && after_digits + 1 < limit
     && (line.[after_digits] = '.' || line.[after_digits] = ')')
     && line.[after_digits + 1] = ' '
  then
    Some
      ( indent
      , String.sub line indent (after_digits - indent + 1)
      , String.sub line (after_digits + 2) (limit - after_digits - 2)
      , after_digits + 2 )
  else None

let quote_body line =
  let start, stop = trim_source_bounds line 0 (String.length line) in
  if start < stop && line.[start] = '>' then
    let body_start, body_stop = trim_source_bounds line (start + 1) stop in
    Some (String.sub line body_start (body_stop - body_start), body_start)
  else None

(* The fenced-code lexers moved to Masc_tui_code_lexer so the Code surface
   can tokenize files without markdown chrome. The alias keeps every
   downstream reference and the emitted bytes unchanged. *)
let lexer_of_language = Masc_tui_code_lexer.lexer_of_language

(* The language tag after a fence marker, ["```ocaml" -> "ocaml"]. An empty
   rest is an untagged fence: no tag, no lexer, no guess. *)
let fence_language line =
  match fence_marker (String.trim line) with
  | None -> None
  | Some marker ->
      let trimmed = String.trim line in
      let rest =
        String.trim
          (String.sub trimmed (String.length marker)
             (String.length trimmed - String.length marker))
      in
      if String.length rest = 0 then None else Some rest

let fence_rows_of_segments = Masc_tui_code_lexer.rows_of_segments

(* Why a mermaid fence shows its source instead of a drawing. *)
let mermaid_failure_text = function
  | Masc_tui_mermaid.Unsupported what ->
      "mermaid: " ^ what ^ " is not drawn here; the source follows"
  | Masc_tui_mermaid.Parse_error { line; what } ->
      Printf.sprintf "mermaid: line %d: %s; the source follows" line what
  | Masc_tui_mermaid.Too_wide { cells; cols; turning_it_fits } ->
      let turn =
        match turning_it_fits with
        | None -> ""
        | Some direction ->
            Printf.sprintf " (as %s it fits)"
              (Masc_tui_mermaid.direction_word direction)
      in
      Printf.sprintf
        "mermaid: the drawing needs %d cells and this pane has %d%s; the source \
         follows"
        cells cols turn

let styled_piece palette (text, kind) =
  if String.length text = 0 then ""
  else
    let opening, closing = span_of_palette palette kind in
    opening ^ text ^ closing

(* One lexed row, cut to the width in pieces rather than in text.

   This used to keep the pieces only while the row fitted and fall back to
   splitting the plain text past it, on the reasoning that a code row keeps
   its alignment before it keeps its colours -- the alignment being why it was
   fenced. The alignment is worth that, but the two are not actually in
   tension: what the lexer hands over is plain text with a kind beside it, and
   the escapes are added after the cut. Cutting the pieces by display cells
   therefore lands on the same columns the text split landed on, and the row
   keeps both.

   What it cost was the rows that most need reading. A line short enough to
   fit kept its colours; a long added line, a memory claim, a wrapped string
   -- the ones a reader slows down for -- lost every one. *)
let wrap_pieces ~max_cells pieces =
  let rows = ref [] and row = ref [] and used = ref 0 in
  let flush () =
    if !row <> [] then rows := List.rev !row :: !rows;
    row := [];
    used := 0
  in
  List.iter
    (fun (text, kind) ->
      let rec place text =
        if String.length text = 0 then ()
        else
          let cells = Layout.display_width text in
          let room = max_cells - !used in
          if cells <= room then begin
            row := (text, kind) :: !row;
            used := !used + cells
          end
          else if room <= 0 then begin
            (* The row is full. [flush] resets [used], so the retry has the
               whole width to place into and cannot come back here. *)
            flush ();
            place text
          end
          else begin
            (* Grapheme-safe: a wide character straddling the cut moves to the
               next row whole. Cutting by cells here would give it up and pad
               its columns, which holds the alignment and loses the letter --
               and a wrapped line of Korean is where that shows. *)
            let head, tail =
              match Layout.split_at_cells text room with
              | "", _ when !row = [] ->
                  (* A grapheme wider than the row itself. [split_cells] takes
                     one piece whatever the width, which is the only rule that
                     ends here; a row one cell over beats never finishing. *)
                  (match Layout.split_cells ~max_cells:room text with
                   | chunk :: _ when String.length chunk > 0 ->
                       ( chunk
                       , String.sub text (String.length chunk)
                           (String.length text - String.length chunk) )
                   | _ -> (text, ""))
              | split -> split
            in
            if String.length head > 0 then row := (head, kind) :: !row;
            flush ();
            (* The remaining rows are full-width. Segment their text once,
               rather than measuring and splitting every shrinking suffix. *)
            let rec place_chunks = function
              | [] -> ()
              | [last] ->
                  row := [(last, kind)];
                  used := Layout.display_width last
              | chunk :: rest ->
                  row := [(chunk, kind)];
                  flush ();
                  place_chunks rest
            in
            if String.length tail > 0 then
              place_chunks (Layout.split_cells ~max_cells tail)
          end
      in
      place text)
    pieces;
  flush ();
  List.rev !rows

let diff_row_span palette pieces =
  let non_empty = List.filter (fun (text, _) -> String.length text > 0) pieces in
  match non_empty with
  | (_, kind) :: rest
    when (String.equal kind kind_code_diff_added
          || String.equal kind kind_code_diff_removed)
         && List.for_all (fun (_, other) -> String.equal kind other) rest ->
      Some (span_of_palette palette kind)
  | _ -> None

let fill_styled_row ~width (opening, closing) text =
  let remaining = max 0 (width - Layout.display_width text) in
  opening ^ text ^ String.make remaining ' ' ^ closing

(* A diff row with token colours underneath: the first run carries the row's
   added or removed kind and the rest lex the content (["```diff:ocaml"]).
   Whole-line rows take [diff_row_span] above and keep their exact bytes,
   so reaching here with a diff-kind first run implies a mixed row. *)
let diff_mixed_kind pieces =
  let non_empty = List.filter (fun (text, _) -> String.length text > 0) pieces in
  match non_empty with
  | (_, kind) :: _
    when String.equal kind kind_code_diff_added
         || String.equal kind kind_code_diff_removed ->
      Some kind
  | _ -> None

(* Close each token before restoring the enclosing diff band. The close may
   reset the background as well as bold/italic; reopening the row span before
   any next visible cell keeps the band continuous without leaking token
   attributes. Wrapped tails refill the same way so a narrow pane cannot turn
   them back into ordinary code. Cell widths measure the plain text; escapes
   are added after the cut, as in [wrap_pieces]. *)
let styled_diff_mixed_rows ?on_row palette ~width kind pieces =
  let gutter = palette.code_gutter in
  let body_width = max 1 (width - Layout.display_width gutter) in
  let opening, closing = span_of_palette palette kind in
  let source_byte = ref 0 in
  wrap_pieces ~max_cells:body_width pieces
  |> List.map (fun row ->
         let plain = gutter ^ String.concat "" (List.map fst row) in
         let styled =
           gutter
           ^ String.concat ""
               (List.map
                  (fun (text, piece_kind) ->
                    if String.length text = 0 then ""
                    else
                      let piece_opening, piece_closing =
                        span_of_palette palette piece_kind
                      in
                      piece_opening ^ text ^ piece_closing ^ opening)
                  row)
         in
         let remaining = max 0 (width - Layout.display_width plain) in
         let text = opening ^ styled ^ String.make remaining ' ' ^ closing in
         let length = List.fold_left (fun total (text, _) -> total + String.length text) 0 row in
         Option.iter (fun emit -> emit {text;
           source_ranges=[{start_byte= !source_byte; end_byte= !source_byte + length}]}) on_row;
         source_byte := !source_byte + length;
         text)

(* One lexed row. Three regimes, and the diff checks come first.

   The diff lexer gives an added or removed row one typed kind from edge to
   edge. That row span includes the gutter and fills the available width;
   every hard-split chunk repeats it, so a narrow pane cannot turn the tail of
   a changed line back into ordinary code. No source-prefix check belongs
   here: the lexer remains the authority for what is a changed row.

   A diff row with token colours underneath keeps its band the same way,
   with each run's foreground over the row's background.

   Every other row wraps as pieces ([wrap_pieces]), so a long code line keeps
   its per-token colours across the wrap instead of falling back to a
   single-span cell split. *)
let styled_code_rows ?on_row palette ~width pieces =
  let gutter = palette.code_gutter in
  let body_width = max 1 (width - Layout.display_width gutter) in
  let plain = String.concat "" (List.map fst pieces) in
  let cells = Layout.display_width plain in
  let source_byte = ref 0 in
  let mapped plain text =
    let length = String.length plain in
    Option.iter (fun emit -> emit {text;
      source_ranges=[{start_byte= !source_byte; end_byte= !source_byte + length}]}) on_row;
    source_byte := !source_byte + length;
    text
  in
  match diff_row_span palette pieces with
  | Some span ->
      let chunks =
        if cells <= body_width then [ plain ]
        else Layout.split_cells ~max_cells:body_width plain
      in
      List.map (fun chunk -> mapped chunk (fill_styled_row ~width span (gutter ^ chunk))) chunks
  | None -> (
      match diff_mixed_kind pieces with
      | Some kind -> styled_diff_mixed_rows ?on_row palette ~width kind pieces
      | None ->
          wrap_pieces ~max_cells:body_width pieces
          |> List.map (fun row ->
               mapped (String.concat "" (List.map fst row))
                 (gutter ^ String.concat "" (List.map (styled_piece palette) row)))
      )

let render_lexed_line_with_spans ~palette ~width pieces =
  let mapped_rows = ref [] in
  let (_ : string list) = styled_code_rows ~on_row:(fun row -> mapped_rows := row :: !mapped_rows)
    palette ~width:(max 1 width) pieces in
  let semantic_text = String.concat "" (List.map fst pieces) in
  {semantic_text; source_positions=Array.init (String.length semantic_text) (fun i -> Some i);
   mapped_rows=List.rev !mapped_rows}

let horizontal cells =
  String.concat "" (List.init (max 0 cells) (fun _ -> "\xe2\x94\x80"))

let styled_span (opening, closing) text = opening ^ text ^ closing

(* The tag was previously consumed only to choose a lexer, so [```bash] and an
   untagged fence looked identical. Fill the row so reverse video can provide a
   terminal-theme-safe background without choosing a light- or dark-only
   colour. A very long tag is clipped as one row; it cannot push the frame. *)
let code_header ?on_language palette ~width language =
  let prefix = "\xe2\x94\x8c\xe2\x94\x80 " in
  let stem = prefix ^ language ^ " " in
  let stem =
    if Layout.display_width stem <= width then stem
    else
      match Layout.split_cells ~max_cells:width stem with
      | first :: _ -> first
      | [] -> ""
  in
  Option.iter (fun emit -> emit (max 0 (min (String.length language)
    (String.length stem - String.length prefix)))) on_language;
  let remaining = max 0 (width - Layout.display_width stem) in
  styled_span palette.code_header (stem ^ horizontal remaining)

let code_footer palette ~width =
  styled_span palette.code_border
    ("\xe2\x94\x94" ^ horizontal (max 0 (width - 1)))

(* Fenced code is not wrapped at spaces: the alignment is the reason it was
   fenced. A line wider than the row is split where the row ends. *)
let code_rows ?on_row palette ~width line =
  let gutter = palette.code_gutter in
  let body_width = max 1 (width - Layout.display_width gutter) in
  let opening, closing = palette.code in
  let source_byte = ref 0 in
  let mapped chunk =
    let text = opening ^ gutter ^ chunk ^ closing in
    let end_byte = !source_byte + String.length chunk in
    Option.iter (fun emit -> emit {text; source_ranges=[{start_byte= !source_byte; end_byte}]}) on_row;
    source_byte := end_byte;
    text in
  if String.length line = 0 then [mapped ""]
  else Layout.split_cells ~max_cells:body_width line |> List.map mapped

(* {1 Tables} *)

(* A table is the one block form that cannot be decided one line at a time. A
   row of pipes is a table only when a delimiter row follows it -- without that
   rule an OCaml [| Some x -> y] pasted outside a fence would become one -- and
   the column widths are a property of every row at once. So the whole block is
   matched together, in [render], where the rest of it is still in hand. *)

type alignment =
  | Left
  | Centre
  | Right

let table_cells_with_offsets line =
  let start, stop = trim_source_bounds line 0 (String.length line) in
  let trimmed = String.sub line start (stop - start) in
  if not (String.contains trimmed '|') then None
  else
    let offset = ref start in
    let parts = String.split_on_char '|' trimmed |> List.map (fun raw ->
      let at = !offset in
      offset := at + String.length raw + 1;
      raw, at) in
    (* Outer pipes are optional; only the empty pieces before trimming are
       dropped, exactly as in the original cell grammar. *)
    let parts = match parts with ("", _) :: rest -> rest | other -> other in
    let parts = match List.rev parts with ("", _) :: rest -> List.rev rest | _ -> parts in
    match parts with
    | [] -> None
    | cells -> Some (List.map (fun (raw, at) ->
        let start, stop = trim_source_bounds raw 0 (String.length raw) in
        String.sub raw start (stop - start), at + start) cells)

let table_cells line =
  Option.map (List.map fst) (table_cells_with_offsets line)

let delimiter_alignment cell =
  let length = String.length cell in
  if length = 0 then None
  else
    let opens = cell.[0] = ':' in
    let closes = length > 1 && cell.[length - 1] = ':' in
    let first = if opens then 1 else 0 in
    let last = if closes then length - 1 else length in
    let dashes = last - first in
    let all_dashes = ref (dashes >= 1) in
    String.iteri
      (fun index char ->
        if index >= first && index < last && char <> '-' then all_dashes := false)
      cell;
    if not !all_dashes then None
    else
      Some
        (match (opens, closes) with
         | true, true -> Centre
         | false, true -> Right
         | true, false | false, false -> Left)

let table_alignments line =
  match table_cells line with
  | None | Some [] -> None
  | Some cells ->
      let alignments = List.map delimiter_alignment cells in
      if List.for_all Option.is_some alignments
      then Some (List.map Option.get alignments)
      else None

(* Every row is drawn with the same number of columns as the delimiter row
   declared: a short row is padded and a long one keeps its overflow in the
   last column rather than being cut, because a cell the source wrote is worth
   more than a straight right edge. *)
let normalise_cells ~empty ~join ~columns cells =
  let rec take taken remaining = function
    | _ when remaining = 0 -> List.rev taken
    | [] -> List.rev taken @ List.init remaining (fun _ -> empty)
    | [ last ] when remaining = 1 -> List.rev (last :: taken)
    | rest when remaining = 1 -> List.rev (join rest :: taken)
    | cell :: rest -> take (cell :: taken) (remaining - 1) rest
  in
  take [] columns cells

let normalise_row ~columns cells =
  normalise_cells ~empty:"" ~join:(String.concat " ") ~columns cells

let table_row_positions ~columns ~source_start line =
  let cells = Option.value (table_cells_with_offsets line) ~default:[] in
  let positions = List.map (fun (text, start) ->
    Array.init (String.length text) (fun byte -> Some (source_start + start + byte))) cells in
  let join parts =
    let rec intersperse = function
      | [] -> [] | [part] -> [part]
      | part :: rest -> part :: [|None|] :: intersperse rest in
    Array.concat (intersperse parts) in
  normalise_cells ~empty:[||] ~join ~columns positions

let pad ~alignment ~cells text =
  let missing = max 0 (cells - Layout.display_width text) in
  match alignment with
  | Left -> text ^ String.make missing ' '
  | Right -> String.make missing ' ' ^ text
  | Centre ->
      let left = missing / 2 in
      String.make left ' ' ^ text ^ String.make (missing - left) ' '

(* Columns get their natural width when the row fits. When it does not, the
   widest column gives up a cell at a time: taking it evenly would shrink a
   two-cell column that costs nothing to keep. *)
let column_widths ~width ~gutter_cells ~columns rows =
  let natural =
    List.init columns (fun index ->
      List.fold_left
        (fun widest row ->
          max widest (Layout.display_width (List.nth row index)))
        1 rows)
  in
  let spacing = gutter_cells * max 0 (columns - 1) in
  let widths = Array.of_list natural in
  let total () = Array.fold_left ( + ) 0 widths + spacing in
  let rec shrink () =
    if total () <= width then ()
    else
      let widest = ref 0 in
      Array.iteri (fun index w -> if w > widths.(!widest) then widest := index) widths;
      if widths.(!widest) <= 1 then ()
      else begin
        widths.(!widest) <- widths.(!widest) - 1;
        shrink ()
      end
  in
  shrink ();
  Array.to_list widths

type table_cell_source = {
  table_row : int;
  table_column : int;
  rendered_row : int;
  cell_text : string;
  source_positions : int option array;
  rendered_start_cell : int;
  visible_range : source_range;
}

let table_block ?on_cell ?source_rows palette ~width ~alignments ~header ~body =
  let columns = List.length alignments in
  let gutter = palette.table_gutter in
  let gutter_cells = Layout.display_width gutter in
  let cell_mapping = Option.map (fun emit -> emit, Hashtbl.create 16) on_cell in
  let styled row_index cells =
    List.mapi
      (fun column cell ->
        Option.iter (fun (_, semantic_cells) ->
          let mapped = render_inline_with_spans ~palette ~width:max_int ~prefix:"" ~continuation:"" cell in
          let source_positions = match source_rows with
            | None -> invalid_arg "Masc_tui_markdown.table_block: missing table source positions"
            | Some rows ->
                let raw_positions=List.nth (List.nth rows row_index) column in
                Array.map (fun position -> Option.bind position (fun at -> raw_positions.(at))) mapped.source_positions in
          Hashtbl.replace semantic_cells (row_index, column) (mapped.semantic_text, source_positions)) cell_mapping;
        match
          wrap_inline palette ~width:max_int ~prefix:"" ~continuation:"" cell
        with
        | [] -> ""
        | row :: _ -> row)
      (normalise_row ~columns cells)
  in
  let header = styled 0 header in
  let body = List.mapi (fun row -> styled (row + 1)) body in
  (* The frame is paid for out of the columns, not out of the pane: a table
     that drew its own width plus a border would run past the frame it sits
     in, the way the origin margin would have. *)
  let frame_cells = if palette.table_frame then 4 else 0 in
  let widths =
    column_widths ~width:(max 1 (width - frame_cells)) ~gutter_cells ~columns
      (header :: body)
  in
  let draw row_index row =
    let cell_start = ref (if palette.table_frame then 2 else 0) in
    List.mapi
      (fun index cell ->
        let cells = List.nth widths index in
        let alignment = List.nth alignments index in
        (* [fit_width] pads on the left as well as truncating, and a cell it
           has padded has no room left for the alignment the delimiter row
           asked for. So it is asked only for the cut. *)
        let fitted =
          if Layout.display_width cell > cells then Layout.fit_width cell cells
          else cell
        in
        Option.iter (fun (emit, semantic_cells) ->
          let cell_text, source_positions = Hashtbl.find semantic_cells (row_index, index) in
          let rendered_row = if row_index = 0 then (if palette.table_frame then 1 else 0)
            else row_index + (if palette.table_frame then 2 else 1) in
          let missing = max 0 (cells - Layout.display_width fitted) in
          let padding = match alignment with Left -> 0 | Right -> missing | Centre -> missing / 2 in
          emit {table_row=row_index; table_column=index; rendered_row; cell_text; source_positions;
            rendered_start_cell= !cell_start + padding;
            visible_range={start_byte=0; end_byte=Layout.fitted_source_bytes cell_text cells}}) cell_mapping;
        cell_start := !cell_start + cells + gutter_cells;
        pad ~alignment ~cells fitted)
      row
    |> String.concat gutter
  in
  let opening, closing = palette.table_header in
  let rule_opening, rule_closing = palette.rule in
  let dashes cells = String.concat "" (List.init cells (fun _ -> "\xe2\x94\x80")) in
  let rule =
    List.map dashes widths |> String.concat palette.table_rule_gutter
  in
  if not palette.table_frame then
    (opening ^ draw 0 header ^ closing)
    :: (rule_opening ^ rule ^ rule_closing)
    :: List.mapi (fun index -> draw (index + 1)) body
  else
    (* The box. Each segment spans its column plus the space on either side,
       so a junction lands exactly where the gutter's bar does and the border
       measures the same cells as the row above it. *)
    let border ~left ~joint ~right =
      rule_opening
      ^ left
      ^ (List.map (fun cells -> dashes (cells + 2)) widths
        |> String.concat joint)
      ^ right ^ rule_closing
    in
    let edged row = rule_opening ^ "\xe2\x94\x82" ^ rule_closing ^ " " ^ row
      ^ " " ^ rule_opening ^ "\xe2\x94\x82" ^ rule_closing in
    border ~left:"\xe2\x94\x8c" ~joint:"\xe2\x94\xac" ~right:"\xe2\x94\x90"
    :: edged (opening ^ draw 0 header ^ closing)
    :: border ~left:"\xe2\x94\x9c" ~joint:"\xe2\x94\xbc" ~right:"\xe2\x94\xa4"
    :: (List.mapi (fun index row -> edged (draw (index + 1) row)) body
       @ [ border ~left:"\xe2\x94\x94" ~joint:"\xe2\x94\xb4"
             ~right:"\xe2\x94\x98" ])

(* The table starting at [line], if one starts there: its delimiter row, the
   body rows that follow it, and what is left of the source. *)
type source_line = {
  source_text : string;
  source_start : int;
  terminal_line : bool;
  synthetic_terminal : bool;
}

let source_lines text =
  let lines = String.split_on_char '\n' text in
  let last_index = List.length lines - 1 in
  let ends_with_newline = String.ends_with ~suffix:"\n" text in
  let offset = ref 0 in
  List.mapi
    (fun index source_text ->
      let source_start = !offset in
      if index < last_index then
        offset := source_start + String.length source_text + 1;
      { source_text;
        source_start;
        terminal_line = index = last_index;
        synthetic_terminal = ends_with_newline && index = last_index;
      })
    lines

let table_at ?on_row line rest =
  match (table_cells line.source_text, rest) with
  | Some header, delimiter :: after -> (
      match table_alignments delimiter.source_text with
      | None -> None
      | Some alignments ->
          Option.iter (fun emit -> emit 0 line) on_row;
          let rec body row_index taken = function
            | next :: more -> (
                match table_cells next.source_text with
                | Some cells when table_alignments next.source_text = None ->
                    Option.iter (fun emit -> emit row_index next) on_row;
                    body (row_index + 1) (cells :: taken) more
                | Some _ | None -> (List.rev taken, next :: more))
            | [] -> (List.rev taken, [])
          in
          let rows, remaining = body 1 [] after in
          Some (header, alignments, rows, remaining))
  | Some _, [] | None, _ -> None

(* One source line outside a fence, as the rows it becomes. Flat rather than
   nested so each block form is readable next to the others. *)
let block_rows ?on_inline palette ~width line =
  let inline ~source_start ~prefix ~continuation body =
    match on_inline with
    | None -> wrap_inline palette ~width ~prefix ~continuation body
    | Some emit ->
        let mapped = render_inline_with_spans ~palette ~width ~prefix ~continuation body in
        emit {mapped with source_positions=Array.map (Option.map ((+) source_start)) mapped.source_positions};
        List.map (fun (row : mapped_row) -> row.text) mapped.mapped_rows
  in
  let heading_rows level body source_start =
    let opening, closing = palette.heading level in
    inline ~source_start ~prefix:"" ~continuation:"" body
    |> List.map (fun row -> opening ^ row ^ closing)
  in
  let quote_rows body source_start =
    let opening, closing = palette.quote in
    inline ~source_start ~prefix:palette.quote_gutter
      ~continuation:palette.quote_gutter body
    |> List.map (fun row -> opening ^ row ^ closing)
  in
  let item_rows ~indent ~marker body source_start =
    let prefix = String.make indent ' ' ^ marker ^ " " in
    let continuation = String.make (Layout.display_width prefix) ' ' in
    inline ~source_start ~prefix ~continuation body
  in
  if String.trim line = "" then [ "" ]
  else if is_rule line then
    let opening, closing = palette.rule in
    [ opening
      ^ String.concat "" (List.init width (fun _ -> "\xe2\x94\x80"))
      ^ closing
    ]
  else
    match heading_level line with
    | Some (level, body, source_start) -> heading_rows level body source_start
    | None -> (
        match quote_body line with
        | Some (body, source_start) -> quote_rows body source_start
        | None -> (
            match bullet_item line with
            | Some (indent, body, source_start) ->
                item_rows ~indent ~marker:palette.bullet body source_start
            | None -> (
                match ordered_item line with
                | Some (indent, marker, body, source_start) -> item_rows ~indent ~marker body source_start
                | None ->
                    inline ~source_start:0 ~prefix:"" ~continuation:"" line)))

type block_render = {
  block_rows : string list;
  inline_source : inline_render option;
}

let render_block_with_spans ~palette ~width line =
  let inline_source = ref None in
  let block_rows = block_rows ~on_inline:(fun source -> inline_source := Some source)
    palette ~width:(max 1 width) line in
  {block_rows; inline_source= !inline_source}

type table_render = {
  table_rows : string list;
  cell_sources : table_cell_source list;
}

let render_table_with_spans ~palette ~width text =
  match source_lines text with
  | [] -> None
  | first :: rest ->
      let source_lines = ref [] in
      match table_at ~on_row:(fun _ line -> source_lines := line :: !source_lines) first rest with
      | None -> None
      | Some (header, alignments, body, remaining)
        when List.for_all (fun line -> line.synthetic_terminal) remaining ->
          let cell_sources = ref [] in
          let source_rows = List.rev !source_lines |> List.map (fun line ->
            table_row_positions ~columns:(List.length alignments) ~source_start:line.source_start line.source_text) in
          let table_rows = table_block ~source_rows ~on_cell:(fun cell -> cell_sources := cell :: !cell_sources)
            palette ~width:(max 1 width) ~alignments ~header ~body in
          Some {table_rows; cell_sources=List.sort (fun a b ->
            compare (a.table_row, a.table_column) (b.table_row, b.table_column)) !cell_sources}
      | Some _ -> None

let closes_fence line ~opened =
  match (fence_marker line, opened) with
  | Some marker, Some opened -> String.equal marker opened
  | Some _, None -> true
  | None, _ -> false

type generated_field = Fence_language | Mermaid_diagnostic

type semantic_origin =
  | Original of source_range
  | Generated of { block_start : int; field : generated_field; byte : int }

type semantic_run = {
  joins_previous : bool;
  semantic_text : string;
  origins : semantic_origin option array;
  visible_rows : (int * source_range list) list;
}

type document_mapping =
  | Complete_document
  | Incomplete_document of (int * Masc_tui_mermaid.missing_label list) list

type document_render = {
  document_rows : string list;
  semantic_runs : semantic_run list;
  mapping : document_mapping;
}

let original_positions base positions =
  Array.map (Option.map (fun byte -> Original {start_byte=base + byte; end_byte=base + byte + 1})) positions

let render_streaming_internal ?on_semantic ?on_unmapped ~palette ~width text =
  let width = max 1 width in
  let rows = ref [] in
  let rendered_rows = ref 0 in
  let block_count = ref 0 in
  let previous_source_start = ref 0 in
  let previous_row_start = ref 0 in
  let mutable_source_start = ref 0 in
  let mutable_row_start = ref 0 in
  let previous_can_absorb_terminal = ref false in
  let mutable_can_absorb_terminal = ref false in
  let mutable_block_started_at_terminal = ref false in
  let emit_all list =
    List.iter
      (fun row ->
        rows := row :: !rows;
        incr rendered_rows)
      list
  in
  let emit_run run = Option.iter (fun emit -> emit run) on_semantic in
  let emit_inline ?(joins_previous=false) ~base (mapped : inline_render) =
    let row_start = !rendered_rows in
    emit_run {joins_previous;semantic_text=mapped.semantic_text;
      origins=original_positions base mapped.source_positions;
      visible_rows=List.mapi (fun i row -> row_start+i, row.source_ranges) mapped.mapped_rows};
    emit_all (List.map (fun row -> row.text) mapped.mapped_rows)
  in
  let emit_code ?(joins_previous=false) ~base line =
    match on_semantic with
    | None -> emit_all (code_rows palette ~width line)
    | Some _ ->
        let mapped=ref [] in
        let (_ : string list)=code_rows ~on_row:(fun row -> mapped:=row :: !mapped) palette ~width line in
        emit_inline ~joins_previous ~base {semantic_text=line;
          source_positions=Array.init (String.length line) (fun byte -> Some byte);
          mapped_rows=List.rev !mapped}
  in
  let emit_generated ~block_start ~field value =
    match on_semantic with
    | None -> emit_all (code_rows palette ~width value)
    | Some _ ->
        let row_start= !rendered_rows in
        let mapped=ref [] in
        let rows=code_rows ~on_row:(fun row -> mapped:=row :: !mapped) palette ~width value in
        emit_run {joins_previous=false;semantic_text=value;
          origins=Array.init (String.length value) (fun byte -> Some (Generated {block_start;field;byte}));
          visible_rows=List.rev !mapped |> List.mapi (fun i row -> row_start+i,row.source_ranges)};
        emit_all rows
  in
  (* A source ending in a newline produces one synthetic empty line from
     [String.split_on_char]. It is still rendered -- [render] has always kept
     that row -- but it cannot close the preceding block: another delta can
     append a table row or fence content immediately after that newline. *)
  let begin_block ~can_absorb_terminal line =
    if not line.synthetic_terminal then begin
      previous_source_start := !mutable_source_start;
      previous_row_start := !mutable_row_start;
      previous_can_absorb_terminal := !mutable_can_absorb_terminal;
      mutable_source_start := line.source_start;
      mutable_row_start := !rendered_rows;
      mutable_can_absorb_terminal := can_absorb_terminal;
      mutable_block_started_at_terminal := line.terminal_line;
      incr block_count
    end
  in
  (* The fence body is held until the fence closes -- or until the text ends,
     an unclosed fence still renders what it holds -- because the lexer reads
     the body whole; its state, a comment opened rows ago, decides the colour
     of rows it has not reached yet. *)
  let emit_fence ~closed ~block_start language lexer rev_body =
    let body = List.rev rev_body in
    let body_text () = String.concat "\n" (List.map (fun line -> line.source_text) body) in
    let body_base = match body with first :: _ -> first.source_start | [] -> block_start in
    Option.iter
      (fun language ->
        let on_language = Option.map (fun _ visible ->
          emit_run {joins_previous=false;semantic_text=language;
            origins=Array.init (String.length language) (fun byte -> Some (Generated {block_start;field=Fence_language;byte}));
            visible_rows=[!rendered_rows, [{start_byte=0;end_byte=visible}]]}) on_semantic in
        emit_all [code_header ?on_language palette ~width language]) language;
    (match language, lexer with
     | Some "mermaid", _ ->
         let body_width = max 1 (width - Layout.display_width palette.code_gutter) in
         (match on_semantic with
          | None -> (match Masc_tui_mermaid.render ~cols:body_width (body_text ()) with
              | Ok rows -> List.iter (fun row -> emit_all (code_rows palette ~width row)) rows
              | Error failure ->
                  emit_all (code_rows palette ~width (mermaid_failure_text failure));
                  List.iter (fun line -> emit_all (code_rows palette ~width line.source_text)) body)
          | Some _ -> (match Masc_tui_mermaid.render_with_source_labels ~cols:body_width (body_text ()) with
              | Error failure ->
                  emit_generated ~block_start ~field:Mermaid_diagnostic (mermaid_failure_text failure);
                  List.iteri (fun i line -> emit_code ~joins_previous:(i>0) ~base:line.source_start line.source_text) body
              | Ok mapped ->
                  let labels = match mapped.labels with
                    | Complete labels -> labels
                    | Incomplete {mapped;missing} ->
                        Option.iter (fun emit -> emit (block_start,missing)) on_unmapped;
                        mapped in
                  let visible=Hashtbl.create 16 in
                  List.iteri (fun canvas_row row ->
                    let on_row (row : mapped_row) =
                      let ranges=Hashtbl.create 8 in
                      List.iter (fun range ->
                        for byte=range.start_byte to range.end_byte-1 do
                          match mapped.rendered_positions.(canvas_row).(byte) with
                          | None -> ()
                          | Some position ->
                              let previous=Option.value (Hashtbl.find_opt ranges position.identity) ~default:[] in
                              Hashtbl.replace ranges position.identity ({start_byte=position.byte;end_byte=position.byte+1}::previous)
                        done) row.source_ranges;
                      Hashtbl.iter (fun identity ranges ->
                        let previous=Option.value (Hashtbl.find_opt visible identity) ~default:[] in
                        Hashtbl.replace visible identity ((!rendered_rows,List.rev ranges)::previous)) ranges;
                      emit_all [row.text] in
                    let (_ : string list)=code_rows ~on_row palette ~width row in ()) mapped.rendered_rows;
                  List.iter (fun (label : Masc_tui_mermaid.sourced_label) ->
                    emit_run {joins_previous=false;semantic_text=label.text;
                      origins=Array.map (fun (range : Masc_tui_mermaid.label_source_range) ->
                        Some (Original {start_byte=body_base+range.start_byte;end_byte=body_base+range.end_byte})) label.ranges;
                      visible_rows=Option.value (Hashtbl.find_opt visible label.identity) ~default:[] |> List.rev}) labels))
     | _, Some lexer ->
         let lines=fence_rows_of_segments (lexer (body_text ())) in
         let source_byte=ref body_base in
         List.iteri (fun i pieces ->
           (match on_semantic with
            | None -> emit_all (styled_code_rows palette ~width pieces)
            | Some _ -> emit_inline ~joins_previous:(i>0) ~base:!source_byte (render_lexed_line_with_spans ~palette ~width pieces));
           source_byte := !source_byte + String.length (String.concat "" (List.map fst pieces)) + 1) lines
     | _, None -> List.iteri (fun i line -> emit_code ~joins_previous:(i>0) ~base:line.source_start line.source_text) body);
    if closed && Option.is_some language then emit_all [code_footer palette ~width]
  in
  let previous_inline=ref false in
  let rec walk fence rev_body = function
    | [] -> (
        match fence with
        | Some (_, language, lexer, block_start) ->
            emit_fence ~closed:false ~block_start language lexer rev_body
        | None -> ())
    | line :: rest -> (
        match fence with
        | Some (marker, language, lexer, block_start)
          when closes_fence line.source_text ~opened:(Some marker) ->
            emit_fence ~closed:true ~block_start language lexer rev_body;
            mutable_can_absorb_terminal := false;
            walk None [] rest
        | Some _ -> walk fence (line :: rev_body) rest
        | None -> (
            match fence_marker line.source_text with
            | Some marker ->
                previous_inline:=false;
                begin_block ~can_absorb_terminal:true line;
                let language = fence_language line.source_text in
                let lexer =
                  Option.bind language lexer_of_language
                in
                walk (Some (marker, language, lexer, line.source_start)) [] rest
            | None -> (
                let table_lines=ref [] in
                let on_row=Option.map (fun _ _ line -> table_lines:=line :: !table_lines) on_semantic in
                match table_at ?on_row line rest with
                | Some (header, alignments, body, remaining) ->
                    previous_inline:=false;
                    begin_block ~can_absorb_terminal:true line;
                    let row_start= !rendered_rows in
                    let source_rows=Option.map (fun _ -> List.rev !table_lines |> List.map (fun line ->
                      table_row_positions ~columns:(List.length alignments) ~source_start:line.source_start line.source_text)) on_semantic in
                    let on_cell=Option.map (fun _ (cell : table_cell_source) ->
                      emit_run {joins_previous=false;semantic_text=cell.cell_text; origins=original_positions 0 cell.source_positions;
                        visible_rows=[row_start+cell.rendered_row,[cell.visible_range]]}) on_semantic in
                    emit_all (table_block ?source_rows ?on_cell palette ~width ~alignments ~header ~body);
                    walk None [] remaining
                | None ->
                    begin_block ~can_absorb_terminal:(Option.is_some (table_cells line.source_text)) line;
                    (match on_semantic with
                     | None -> emit_all (block_rows palette ~width line.source_text)
                     | Some _ ->
                         let mapped=render_block_with_spans ~palette ~width line.source_text in
                         Option.iter (fun (inline : inline_render) ->
                           emit_run {joins_previous= !previous_inline;semantic_text=inline.semantic_text;
                             origins=original_positions line.source_start inline.source_positions;
                             visible_rows=List.mapi (fun i row -> !rendered_rows+i,row.source_ranges) inline.mapped_rows}) mapped.inline_source;
                         let blank=String.trim line.source_text="" in
                         if blank then emit_run {joins_previous= !previous_inline;semantic_text="";
                           origins=[||];visible_rows=[]};
                         previous_inline:=Option.is_some mapped.inline_source || blank;
                         emit_all mapped.block_rows);
                    walk None [] rest)))
  in
  walk None [] (source_lines text);
  let terminal_can_join_previous = !previous_can_absorb_terminal in
  let mutable_source_start, mutable_row_start =
    (* An incomplete final physical line can still turn into a table delimiter
       for a header candidate before it, or into another row of a table. Keep
       that predecessor mutable until a newline proves the separation. Other
       preceding blocks are already closed. A final line already inside a
       fence or table never called [begin_block], so its real boundary remains. *)
    if
      !mutable_block_started_at_terminal
      && !block_count > 1
      && terminal_can_join_previous
    then
      !previous_source_start, !previous_row_start
    else !mutable_source_start, !mutable_row_start
  in
  { rows = List.rev !rows;
    mutable_source_start;
    mutable_row_start;
  }

let render_streaming ~palette ~width text =
  render_streaming_internal ~palette ~width text

let render_document_with_spans ~palette ~width text =
  let runs=ref [] and unmapped=ref [] in
  let rendered=render_streaming_internal
    ~on_semantic:(fun run -> runs:=run :: !runs)
    ~on_unmapped:(fun missing -> unmapped:=missing :: !unmapped)
    ~palette ~width text in
  {document_rows=rendered.rows; semantic_runs=List.rev !runs;
   mapping=(match !unmapped with [] -> Complete_document | missing -> Incomplete_document (List.rev missing))}

let render ~palette ~width text =
  (* A single non-fence line is one block; streaming adds no context to it. *)
  if not (String.contains text '\n') && Option.is_none (fence_marker text) then
    block_rows palette ~width:(max 1 width) text
  else (render_streaming ~palette ~width text).rows
