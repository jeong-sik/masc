let maximum ~count ~height = Int.max 0 (count - height)

let normalize ~count ~height scroll =
  Int.max 0 (Int.min scroll (maximum ~count ~height))

(* A page keeps one row from the window it leaves. Moving a full [height]
   would put the row the reader stopped on just past the edge, so a long list
   read page by page loses one row per press with nothing saying so. *)
let page_step ~height = Int.max 1 (height - 1)

module Position = struct
  type t = Offset of int | End
  type movement = First | Last | By of int | Page_down | Page_up
  let first = Offset 0
  let is_end = function End -> true | Offset _ -> false
  let at value = Offset (max 0 value)
  let offset ~count ~height = function
    | Offset value -> normalize ~count ~height value
    | End -> maximum ~count ~height
  let clamp ~count ~height = function
    | Offset value -> Offset (normalize ~count ~height value)
    | End -> End
  let move ~count ~height movement position =
    let by delta =
      let current = offset ~count ~height position in
      Offset (if delta > 0 then
        min (maximum ~count ~height)
          (current + min delta (max_int - current))
      else max 0 (current + delta))
    in
    match movement with
    | First -> first
    | Last -> End
    | By delta -> by delta
    | Page_down -> by (page_step ~height)
    | Page_up -> by (-(page_step ~height))
end

let down ~count ~height scroll =
  Int.min (maximum ~count ~height) (normalize ~count ~height scroll + 1)

let up ~count ~height scroll = Int.max 0 (normalize ~count ~height scroll - 1)

let step_uncounted ~delta scroll =
  if delta > 0 && scroll > max_int - delta then max_int
  else Int.max 0 (scroll + delta)

let page_down ~count ~height scroll =
  Int.min
    (maximum ~count ~height)
    (normalize ~count ~height scroll + page_step ~height)

let page_up ~count ~height scroll =
  Int.max 0 (normalize ~count ~height scroll - page_step ~height)

type key_move = Line_down | Line_up | Page_down | Page_up | To_top | To_end

(* Each sheet matched its own key names against these movers, and no two
   agreed: the cheat sheet moved a page by the whole window and had no Home or
   End, the agenda kept a row between pages, and the context reader scrolled
   by page, Home and End on one tab and by line on the others. *)
let move_of_key = function
  | "j" | "down" -> Some Line_down
  | "k" | "up" -> Some Line_up
  | "pagedown" -> Some Page_down
  | "pageup" -> Some Page_up
  | "g" | "home" -> Some To_top
  | "G" | "end" -> Some To_end
  | _ -> None

let apply_move ~count ~height move scroll =
  match move with
  | Line_down -> down ~count ~height scroll
  | Line_up -> up ~count ~height scroll
  | Page_down -> page_down ~count ~height scroll
  | Page_up -> page_up ~count ~height scroll
  | To_top -> 0
  | To_end -> maximum ~count ~height

let cursor_last ~count = Int.max 0 (count - 1)

(* Not in the interface: every mover below normalises through it, and an
   exported clamp with no caller outside is a surface the ratchet counts.
   The upper bound is {!cursor_last} rather than a second [count - 1], so
   "the last row" has one spelling and End cannot land past where a step
   can reach. *)
let cursor_normalized ~count cursor = Int.max 0 (Int.min cursor (cursor_last ~count))

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

let ensure_span_visible ~start ~stop ~height scroll =
  if stop < scroll then start
  else if start >= scroll + height then start - height + 1
  else Int.max 0 scroll

let ensure_visible ~cursor ~height scroll =
  if cursor < scroll then cursor
  else if cursor > scroll + height - 1 then cursor - height + 1
  else Int.max 0 scroll

(* A group heading is no row the cursor can name, so [ensure_visible] let it
   scroll off the top whenever the cursor stood on the group's first row: Home
   on a grouped list, and every k across a group boundary, showed a row whose
   group name had just gone. The lead is held to what a window shows together
   with the row, so the row itself never leaves. *)
let ensure_visible_with_lead ~cursor ~lead ~height scroll =
  let lead = Int.max 0 (Int.min lead (Int.min cursor (height - 1))) in
  ensure_visible ~cursor:(cursor - lead) ~height (ensure_visible ~cursor ~height scroll)

let window_of_heights ~heights ~cursor ~rows scroll =
  let heights = Array.of_list heights in
  let count = Array.length heights in
  if count = 0 || rows <= 0 then 0, 0
  else
    (* [before.(i)] is the lines the items ahead of item [i] take. *)
    let before = Array.make (count + 1) 0 in
    Array.iteri (fun i height -> before.(i + 1) <- before.(i) + height) heights;
    let lines ~first ~stop = before.(stop) - before.(first) in
    let cursor = Int.max 0 (Int.min cursor (count - 1)) in
    let rec bottom first =
      if first > 0 && lines ~first:(first - 1) ~stop:count <= rows then bottom (first - 1)
      else first
    in
    let rec down first =
      if first < cursor && lines ~first ~stop:(cursor + 1) > rows then down (first + 1)
      else first
    in
    let first =
      Int.min (bottom count) (if cursor < scroll then cursor else down (Int.max 0 scroll))
    in
    let rec fitting stop =
      if stop < count && lines ~first ~stop:(stop + 1) <= rows then fitting (stop + 1) else stop
    in
    first, fitting first - first

let preview_height ~total ~keep = Int.max 0 (Int.min (total - keep) (total / 2))
let body_height ~total ~keep = Int.max 1 (total - preview_height ~total ~keep)

let content_height ~rows ~chrome ~count ~preview_keep ~overflow_takes_row =
  let total = Int.max 1 (rows - chrome) in
  let total =
    match preview_keep with
    | None -> total
    | Some _ when count = 0 -> total
    | Some keep -> body_height ~total ~keep
  in
  if overflow_takes_row && count > total then Int.max 1 (total - 1) else total

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
    let first = Int.max 0 (Int.min scroll (count - 1)) in
    Printf.sprintf "%d-%d/%d" (first + 1) (Int.min count (first + height)) count

let window_reading ~noun ~scroll ~height count =
  noun ^ " " ^ window_text ~scroll ~height count

(* The reading goes first and the hint after it, both indented like a body
   row. The overlays wrote "  [lines ...]", the Changes diff and the tree diff
   "[lines ...]  esc closes" flush against the frame, and the patch review
   put it in its footer, where the fitter reads it as one more key item
   (#38820). *)
let position_row ~ko ~scroll ~height ?hint count =
  let reading =
    if count > height then
      Some
        (Printf.sprintf (if ko then "[줄 %s]" else "[lines %s]")
           (window_text ~scroll ~height count))
    else None
  in
  match reading, hint with
  | None, None -> None
  | Some reading, None -> Some ("  " ^ reading)
  | None, Some hint -> Some ("  " ^ hint)
  | Some reading, Some hint -> Some ("  " ^ reading ^ "  " ^ hint)
