type style =
  | User
  | Keeper
  | Status
  | Error

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
  else if Uucp.Emoji.is_emoji_presentation scalar then 2
  else max 0 (Uucp.Break.tty_width_hint scalar)

let next_piece text offset =
  match ansi_csi_end text offset with
  | Some next -> `Ansi next
  | None ->
      let decoded = String.get_utf_8_uchar text offset in
      let scalar_length = max 1 (Uchar.utf_decode_length decoded) in
      let width =
        if Uchar.utf_decode_is_valid decoded then
          scalar_cell_width (Uchar.utf_decode_uchar decoded)
        else 1
      in
      `Scalar (min (String.length text) (offset + scalar_length), width)

let display_width text =
  let rec loop offset width =
    if offset >= String.length text then width
    else
      match next_piece text offset with
      | `Ansi next -> loop next width
      | `Scalar (next, scalar_width) -> loop next (width + scalar_width)
  in
  loop 0 0

let cell_prefix text max_cells =
  let buffer = Buffer.create (String.length text) in
  let rec loop offset used_cells saw_ansi =
    if offset >= String.length text then
      Buffer.contents buffer, used_cells, saw_ansi
    else
      match next_piece text offset with
      | `Ansi next ->
          Buffer.add_substring buffer text offset (next - offset);
          loop next used_cells true
      | `Scalar (next, scalar_width)
        when used_cells + scalar_width <= max_cells ->
          Buffer.add_substring buffer text offset (next - offset);
          loop next (used_cells + scalar_width) saw_ansi
      | `Scalar _ -> Buffer.contents buffer, used_cells, saw_ansi
  in
  loop 0 0 false

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
  let rec pieces offset reversed =
    if offset >= String.length text then reversed
    else
      match next_piece text offset with
      | `Ansi next -> pieces next ((offset, next, 0) :: reversed)
      | `Scalar (next, width) ->
          pieces next ((offset, next, width) :: reversed)
  in
  let rec start_offset used current_start = function
    | [] -> current_start
    | (start, _next, width) :: rest when used + width <= max_cells ->
        start_offset (used + width) start rest
    | _ -> current_start
  in
  let start = start_offset 0 (String.length text) (pieces 0 []) in
  let rec drop_detached_zero_width offset =
    if offset >= String.length text then offset
    else
      match next_piece text offset with
      | `Ansi next -> drop_detached_zero_width next
      | `Scalar (next, 0) -> drop_detached_zero_width next
      | `Scalar _ -> offset
  in
  let start = drop_detached_zero_width start in
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

let take_last count values =
  let drop = max 0 (List.length values - max 0 count) in
  values |> List.filteri (fun index _ -> index >= drop)

let split_cells ~max_cells text =
  if String.equal text "" then [ "" ]
  else
    let length = String.length text in
    let rec take offset used_cells =
      if offset >= length then offset
      else
        match next_piece text offset with
        | `Ansi next -> take next used_cells
        | `Scalar (next, scalar_width) ->
            if used_cells > 0 && used_cells + scalar_width > max_cells then
              offset
            else if used_cells = 0 && scalar_width > max_cells then next
            else take next (used_cells + scalar_width)
    in
    let rec loop offset rows =
      if offset >= length then List.rev rows
      else
        let next = take offset 0 in
        let chunk = String.sub text offset (next - offset) in
        loop next (chunk :: rows)
    in
    loop 0 []

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
