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

let grapheme_cell_width grapheme =
  let rec loop offset width max_width has_hangul_l has_hangul_vt =
    if offset >= String.length grapheme then
      if has_hangul_l && has_hangul_vt then max_width else width
    else
      let decoded = String.get_utf_8_uchar grapheme offset in
      let valid = Uchar.utf_decode_is_valid decoded in
      let scalar_length = max 1 (Uchar.utf_decode_length decoded) in
      if not valid then
        loop (offset + scalar_length) (width + 1) (max 1 max_width)
          has_hangul_l has_hangul_vt
      else
        let scalar = Uchar.utf_decode_uchar decoded in
        let scalar_width = scalar_cell_width scalar in
        let hangul_type = Uucp.Hangul.syllable_type scalar in
        loop (offset + scalar_length) (width + scalar_width)
          (max max_width scalar_width)
          (has_hangul_l || hangul_type = `L)
          (has_hangul_vt || hangul_type = `V || hangul_type = `T)
  in
  loop 0 0 0 false false

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

let grapheme_pieces text start_offset end_offset reversed =
  if start_offset >= end_offset then reversed
  else
    let run = String.sub text start_offset (end_offset - start_offset) in
    if not (String.is_valid_utf_8 run) then
      scalar_pieces text start_offset end_offset reversed
    else
      Uuseg_string.fold_utf_8 `Grapheme_cluster
        (fun (offset, reversed) grapheme ->
          let next = offset + String.length grapheme in
          ( next
          , { start_offset = offset;
              end_offset = next;
              cell_width = grapheme_cell_width grapheme;
              ansi = false;
            }
            :: reversed ))
        (start_offset, reversed) run
      |> snd

let display_pieces text =
  let length = String.length text in
  let rec find_ansi offset =
    if offset >= length then None
    else
      match ansi_csi_end text offset with
      | Some next -> Some (offset, next)
      | None -> find_ansi (offset + 1)
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

let display_width text =
  display_pieces text
  |> List.fold_left (fun width piece -> width + piece.cell_width) 0

let cell_prefix text max_cells =
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
  loop 0 false (display_pieces text)

let fit_width text width =
  if width <= 0 then ""
  else
    let cells = display_width text in
    if cells > width then
      let prefix, prefix_cells, saw_ansi = cell_prefix text (width - 1) in
      let reset = if saw_ansi then "\x1B[0m" else "" in
      prefix ^ reset ^ String.make (width - 1 - prefix_cells) ' ' ^ "~"
    else text ^ String.make (width - cells) ' '

let cell_suffix text max_cells =
  let rec start_offset used current_start = function
    | [] -> current_start
    | piece :: rest when used + piece.cell_width <= max_cells ->
        start_offset (used + piece.cell_width) piece.start_offset rest
    | _ -> current_start
  in
  let pieces = display_pieces text in
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

let input_viewport ~max_cells input =
  let max_cells = max 0 max_cells in
  if display_width input <= max_cells then input
  else if max_cells = 0 then ""
  else "~" ^ cell_suffix input (max_cells - 1)

let input_cursor_row ~terminal_rows ~history_height ~status_rows =
  let last_row = max 1 terminal_rows in
  let candidate = 5 + max 0 history_height + max 0 status_rows in
  min last_row (max 1 candidate)

let input_cursor_column ~terminal_cols ~input =
  let last_column = max 1 (terminal_cols - 1) in
  min last_column (7 + display_width input)

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

let wrap_words ~max_cells text =
  let max_cells = max 1 max_cells in
  let rec loop rows current = function
    | [] -> List.rev (if String.equal current "" then rows else current :: rows)
    | word :: rest as words ->
        let candidate =
          if String.equal current "" then word else current ^ " " ^ word
        in
        if display_width candidate <= max_cells then loop rows candidate rest
        else if not (String.equal current "") then
          loop (current :: rows) "" words
        else
          let chunks = split_cells ~max_cells word in
          (match List.rev chunks with
           | [] -> loop rows "" rest
           | last :: reversed_completed ->
               let completed = List.rev reversed_completed in
               let rows =
                 List.fold_left (fun rows chunk -> chunk :: rows) rows completed
               in
               loop rows last rest)
  in
  loop [] "" (String.split_on_char ' ' text)

let rows_of_entry ~inner_width entry =
  let metadata, _, _ =
    Printf.sprintf "[%s] %s %s" entry.timestamp entry.role_label
      entry.request_label
    |> fun text -> cell_prefix text inner_width
  in
  let body_width = max 4 (inner_width - 2) in
  let body_chunks =
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

let visible_rows ~inner_width ~height entries =
  let inner_width = max 1 inner_width in
  let height = max 0 height in
  let rec collect remaining selected = function
    | [] -> selected
    | _ when remaining = 0 -> selected
    | entry :: older ->
        let rows = rows_of_entry ~inner_width entry in
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
