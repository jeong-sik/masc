let maximum ~count ~height = max 0 (count - height)

let normalize ~count ~height scroll =
  max 0 (min scroll (maximum ~count ~height))

let down ~count ~height scroll =
  min (maximum ~count ~height) (normalize ~count ~height scroll + 1)

let up ~count ~height scroll = max 0 (normalize ~count ~height scroll - 1)

let step_uncounted ~delta scroll = max 0 (scroll + delta)

(* A page keeps one row from the window it leaves. Moving a full [height]
   would put the row the reader stopped on just past the edge, so a long list
   read page by page loses one row per press with nothing saying so. *)
let page_step ~height = max 1 (height - 1)

let page_down ~count ~height scroll =
  min
    (maximum ~count ~height)
    (normalize ~count ~height scroll + page_step ~height)

let page_up ~count ~height scroll =
  max 0 (normalize ~count ~height scroll - page_step ~height)

let cursor_last ~count = max 0 (count - 1)

(* Not in the interface: every mover below normalises through it, and an
   exported clamp with no caller outside is a surface the ratchet counts.
   The upper bound is {!cursor_last} rather than a second [count - 1], so
   "the last row" has one spelling and End cannot land past where a step
   can reach. *)
let cursor_normalized ~count cursor = max 0 (min cursor (cursor_last ~count))

(* A cursor moved by however many rows the key asked for. The two steppers
   below were the only movers, and a caller that wanted a page had nowhere to
   say so: [move_row_cursor] passed a page-sized delta and the stepper read
   only its sign, so PageUp and PageDown moved one row on every surface that
   moves a cursor. Normalising both the start and the landing keeps the
   stale-list rule the steppers already had. *)
let cursor_move ~count ~delta cursor =
  cursor_normalized ~count (cursor_normalized ~count cursor + delta)

let cursor_down ~count cursor = cursor_move ~count ~delta:1 cursor
let cursor_up ~count cursor = cursor_move ~count ~delta:(-1) cursor

let ensure_visible ~cursor ~height scroll =
  if cursor < scroll then cursor
  else if cursor > scroll + height - 1 then cursor - height + 1
  else max 0 scroll

let preview_height ~total ~keep = max 0 (min (total - keep) (total / 2))
let body_height ~total ~keep = max 1 (total - preview_height ~total ~keep)

let content_height ~rows ~chrome ~count ~preview_keep ~overflow_takes_row =
  let total = max 1 (rows - chrome) in
  let total =
    match preview_keep with
    | None -> total
    | Some _ when count = 0 -> total
    | Some keep -> body_height ~total ~keep
  in
  if overflow_takes_row && count > total then max 1 (total - 1) else total

(* Where a window stands in its list, as the first and last rows it shows and
   the count: "27-52/80". Five surfaces wrote their own. Board and the Keeper
   call list said "rows 27-52 of 80", the lane run panes and the question
   reader "27-52/80", and the Keeper detail pane "[1/5]" -- its scroll offset
   over the offsets it could take, a number no row on screen carried. The call
   list fell back to the first row over the count when the long form did not
   fit. *)
let window_text ~scroll ~height count =
  if count <= 0 then "0/0"
  else if height <= 0 then Printf.sprintf "0/%d" count
  else
    let first = max 0 (min scroll (count - 1)) in
    Printf.sprintf "%d-%d/%d" (first + 1) (min count (first + height)) count
