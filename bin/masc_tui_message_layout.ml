type style =
  | User
  | Keeper
  | Status
  | Error
  | Tool
  | Thinking

type entry = {
  style : style;
  timestamp : string;
  role_label : string;
  request_label : string;
  body : string;
}

type row = {
  style : style;
  text : string;
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

let scroll_hint ~scrolled_back ~older_exist =
  if scrolled_back <= 0 then "up:scroll back"
  else if older_exist then
    Printf.sprintf "up/down:scroll  Ctrl-E:newest  (%d back)" scrolled_back
  else
    (* At the oldest row with nothing more to fetch that is the more useful
       fact than the distance: an operator pressing up against a pane that will
       not move should know it is the start of the conversation rather than a
       stuck key, and at the start the distance says what "start" already
       says. Saying both is also what would have made this hint wider than the
       one it replaced. *)
    "up/down:scroll  Ctrl-E:newest  (start of conversation)"

let input_cursor_column ~terminal_cols ~input =
  let last_column = max 1 (terminal_cols - 1) in
  (* Three things sit left of the caret: the box, the prompt, and what was
     typed -- and the caret goes one cell past the last of them. Deriving this
     from the prompt alone put it on the prompt's own ">" instead of after the
     text, because the constant it replaced was all three added up rather than
     the prompt's width. *)
  min last_column
    (chat_input_box_cells + chat_input_prompt_cells + display_width input + 1)

(* Metadata rows read down the pane as a column: [timestamp] speaker request.
   Speakers vary in width, so every role label is padded to one fixed column
   and a too-long speaker truncates with an ellipsis rather than pushing the
   column out for everyone else. *)
let chat_role_label_column = 16

let align_role_label label =
  let pieces = display_pieces label in
  let cells = pieces_width pieces in
  if cells > chat_role_label_column then
    let prefix, _, _ = cell_prefix_of_pieces label pieces (chat_role_label_column - 1) in
    prefix ^ "…"
  else label ^ String.make (chat_role_label_column - cells) ' '

let message_viewport_supported ~terminal_rows ~terminal_cols ~status_rows =
  terminal_cols >= 11 && terminal_rows >= 8 + max 0 status_rows

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

let rows_of_entry ?markdown ~inner_width entry =
  let metadata, _, _ =
    Printf.sprintf "[%s] %s %s" entry.timestamp entry.role_label
      entry.request_label
    |> fun text -> cell_prefix text inner_width
  in
  let body_width = max 4 (inner_width - 2) in
  (* Keepers write markdown. Rendering it is the caller's to supply, so this
     module keeps no terminal vocabulary; without it the body is wrapped as the
     plain text it always was. *)
  let body_chunks =
    match markdown with
    | Some render -> render ~width:body_width entry.body
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
    body_chunks
    |> List.map (fun chunk -> { style = entry.style; text = "  " ^ chunk })
  in
  { style = entry.style; text = metadata } :: body_rows

let visible_rows ?markdown ~inner_width ~height entries =
  let inner_width = max 1 inner_width in
  let height = max 0 height in
  let rec collect remaining selected = function
    | [] -> selected
    | _ when remaining = 0 -> selected
    | entry :: older ->
        let rows = rows_of_entry ?markdown ~inner_width entry in
        let chosen =
          if List.length rows <= remaining then rows
          else if selected = [] then
            match rows with
            | [] -> []
            | metadata :: body ->
                metadata :: take_last (remaining - 1) body
          else take_last remaining rows
        in
        collect (remaining - List.length chosen) (chosen @ selected) older
  in
  collect height [] (List.rev entries)

let total_rows ?markdown ~inner_width entries =
  let inner_width = max 1 inner_width in
  List.fold_left
    (fun total entry ->
       total + List.length (rows_of_entry ?markdown ~inner_width entry))
    0 entries

let max_scroll ?markdown ~inner_width ~height entries =
  max 0 (total_rows ?markdown ~inner_width entries - max 1 height)

(* Nothing older than the newest [from_bottom + height] rows can reach the
   window, so the walk stops once it holds them. Laying out the whole
   transcript to slice a screenful out of the end made every scrolled frame
   cost what the conversation had accumulated. *)
let scrolled_rows ?markdown ~inner_width ~height ~from_bottom entries =
  if from_bottom <= 0 then visible_rows ?markdown ~inner_width ~height entries
  else begin
    let inner_width = max 1 inner_width in
    let height = max 0 height in
    let wanted = from_bottom + height in
    let rec collect gathered gathered_count = function
      | [] -> gathered, gathered_count
      | _ when gathered_count >= wanted -> gathered, gathered_count
      | entry :: older ->
          let rows = rows_of_entry ?markdown ~inner_width entry in
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
let clamp_scroll ?markdown ~inner_width ~height requested entries =
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
            (total + List.length (rows_of_entry ?markdown ~inner_width entry))
            older
    in
    min requested (max 0 (count 0 (List.rev entries) - height))
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

let age_text ~now ~since =
  let seconds = now -. since in
  if seconds < 0. then None
  else
    let whole = int_of_float seconds in
    if whole < 60 then Some (Printf.sprintf "%ds" whole)
    else Some (Printf.sprintf "%dm%02ds" (whole / 60) (whole mod 60))
