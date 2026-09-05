let threshold_cols = 110
(* A 30-cell pane left 23 cells for the name after the border, health mark,
   and spacing. That cut ordinary configured names such as
   [pinewood-pr-jira-checker] even on a 173-column terminal, while the chat
   beside it still had more than 130 cells. Four more cells keep that name
   whole and remain a bounded, stable split: resizing still changes message
   wrapping only when the pane itself appears or disappears. *)
let pane_cols = 34

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
    (* A row the cursor is not on still has to be identifiable. [fit_width]
       kept the head and dropped the tail, so every keeper sharing a prefix
       read the same -- "rw-e0-r9-20260820-revi~" says nothing the next one
       does not. Dropping the middle keeps both the family and the deciding
       end. The cursor row still scrolls the whole name below. *)
    Masc_tui_message_layout.fit_middle width name
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

let toggle_hidden ~hidden ~cols =
  if cols < threshold_cols then None else Some (not hidden)

let content_cols ~hidden ~cols =
  if shown ~hidden ~cols then cols - pane_cols else cols

(* A pane that is not drawn cannot hold a keypress.

   Focus beside the detail is a stored preference, and on its own it is not
   the answer: the reader can put the roster away with Ctrl-B, and the
   terminal can be too narrow to draw it. Either way the detail is the only
   pane on screen. Trusting the preference sent arrows to a cursor nobody
   could see -- and with the selection already at the end of the roster,
   moved nothing at all, which reads as a dead key. *)
let arrows_go_left ~hidden ~cols ~preferring_left =
  preferring_left && shown ~hidden ~cols
