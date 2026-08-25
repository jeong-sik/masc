let threshold_cols = 110
let pane_cols = 30

(* A long selected name travels one cell at a time, pauses at both ends, then
   comes back. Only the selected row uses this offset; moving every name in a
   roster makes the pane harder to scan than static truncation. *)
let marquee_hold_frames = 5

let marquee_offset ~frame ~overflow =
  let overflow = max 0 overflow in
  if overflow = 0 then 0
  else
    let frame = max 0 frame in
    let leg = marquee_hold_frames + overflow in
    let phase = frame mod (2 * leg) in
    if phase < marquee_hold_frames then 0
    else if phase < leg then phase - marquee_hold_frames + 1
    else if phase < leg + marquee_hold_frames then overflow
    else overflow - (phase - leg - marquee_hold_frames + 1)

let name_window ~selected ~frame ~width name =
  let width = max 0 width in
  let cells = Masc_tui_message_layout.display_width name in
  if (not selected) || cells <= width || width < 3 then
    Masc_tui_message_layout.fit_width name width
  else
    (* Edge ellipses remain fixed while the name moves behind them. They say
       which side still contains text without turning the identity itself into
       a guessed abbreviation. *)
    let window = width - 2 in
    let overflow = max 0 (cells - window) in
    let offset = marquee_offset ~frame ~overflow in
    let remaining = Masc_tui_message_layout.drop_cells name offset in
    let chunk =
      match Masc_tui_message_layout.split_cells ~max_cells:window remaining with
      | first :: _ -> first
      | [] -> ""
    in
    let left = if offset > 0 then "\xe2\x80\xa6" else " " in
    let right = if offset + window < cells then "\xe2\x80\xa6" else " " in
    left ^ Masc_tui_message_layout.fit_width chunk window ^ right

let shown ~hidden ~cols = (not hidden) && cols >= threshold_cols

let content_cols ~hidden ~cols =
  if shown ~hidden ~cols then cols - pane_cols else cols
