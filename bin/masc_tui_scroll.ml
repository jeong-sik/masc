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

let wheel_or_key_move ?(vim_edges = true) = function
  | "wheel-down" -> Some Line_down
  | "wheel-up" -> Some Line_up
  | "g" when not vim_edges -> None
  | "G" when not vim_edges -> None
  | key -> move_of_key key

let apply_move ~count ~height move scroll =
  match move with
  | Line_down -> down ~count ~height scroll
  | Line_up -> up ~count ~height scroll
  | Page_down -> page_down ~count ~height scroll
  | Page_up -> page_up ~count ~height scroll
  | To_top -> 0
  | To_end -> maximum ~count ~height

let rec last_of = function
  | [] -> None
  | [ x ] -> Some x
  | _ :: rest -> last_of rest

let visible_target_for_scroll ~targets ~scroll ~height ~current move =
  if height <= 0 then None
  else
    let scroll = Int.max 0 scroll in
    let visible =
      List.filter (fun idx -> idx >= scroll && idx - scroll < height) targets
    in
    match visible with
    | [] -> None
    | first :: _ -> (
        match move with
        | To_top -> Some first
        | To_end -> last_of visible
        | Page_down | Line_down -> (
            match current with
            | None -> Some first
            | Some prev ->
                let delta =
                  match move with
                  | Page_down -> page_step ~height
                  | Line_down -> 1
                  | Line_up | Page_up | To_top | To_end -> 0
                in
                let desired =
                  if prev > max_int - delta then max_int else prev + delta
                in
                (match List.find_opt (fun idx -> idx >= desired) visible with
                 | Some hit -> Some hit
                 | None -> last_of visible))
        | Page_up | Line_up -> (
            match current with
            | None -> last_of visible
            | Some prev ->
                let delta =
                  match move with
                  | Page_up -> page_step ~height
                  | Line_up -> 1
                  | Line_down | Page_down | To_top | To_end -> 0
                in
                let desired =
                  if prev < min_int + delta then min_int else prev - delta
                in
                (match List.find_opt (fun idx -> idx <= desired) (List.rev visible) with
                 | Some hit -> Some hit
                 | None -> Some first)))

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

module Cursor_move = struct
  type t =
    | Line_down
    | Line_up
    | Page_down of int
    | Page_up of int
    | To_top
    | To_end
end

(* The six move keys over a cursor, in one match. Lists used to spell the
   line keys in one place and the edge and page keys in another, each over
   its own count, and the two could walk different lists: the Keeper list's
   j and k stepped over its headings while Home counted only Keepers and
   landed inside a folded group. *)
let cursor_apply ~count (move : Cursor_move.t) cursor =
  match move with
  | Line_down -> cursor_move ~count ~delta:1 cursor
  | Line_up -> cursor_move ~count ~delta:(-1) cursor
  | Page_down page -> cursor_move ~count ~delta:(Int.max 1 page) cursor
  | Page_up page -> cursor_move ~count ~delta:(-Int.max 1 page) cursor
  | To_top -> 0
  | To_end -> cursor_last ~count

let cursor_move_of_key_move ~page = function
  | Line_down -> Cursor_move.Line_down
  | Line_up -> Cursor_move.Line_up
  | Page_down -> Cursor_move.Page_down (Int.max 1 page)
  | Page_up -> Cursor_move.Page_up (Int.max 1 page)
  | To_top -> Cursor_move.To_top
  | To_end -> Cursor_move.To_end

(* A run that fits is a row of several lines: it is on screen whole or the
   reader cannot read it, so a step that leaves its tail under the window
   brings that tail to the bottom. Only a run taller than the window is
   read inside, line by line, and a window on any of its lines stands. *)
let ensure_span_visible ~start ~stop ~height scroll =
  if stop - start + 1 <= height then
    if start < scroll then start
    else if stop >= scroll + height then stop - height + 1
    else Int.max 0 scroll
  else if stop < scroll then start
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

(* A page over items of different heights is a count of items, and the
   count a window holds depends on where it starts: three short items or one
   tall one. A page of the count the window holds now can pass an item when
   the next window holds fewer, so the page is the fewest any window holds.
   A run that reaches the last item holds no fewer than the window it starts:
   nothing past it is left to pass. *)
let items_always_shown ~heights ~rows =
  let heights = Array.of_list heights in
  let count = Array.length heights in
  let rec fitting first taken used =
    if first + taken >= count then None
    else
      let used = used + heights.(first + taken) in
      if used > rows then Some taken else fitting first (taken + 1) used
  in
  let fewest = ref count in
  for first = 0 to count - 1 do
    Option.iter (fun taken -> fewest := Int.min !fewest taken) (fitting first 0 0)
  done;
  Int.max 1 !fewest

let preview_height ~total ~keep = Int.max 0 (Int.min (total - keep) (total / 2))
let body_height ~total ~keep = Int.max 1 (total - preview_height ~total ~keep)

let content_height ~rows ~chrome ~count ~preview_keep =
  let total = Int.max 1 (rows - chrome) in
  match preview_keep with
  | None -> total
  | Some _ when count = 0 -> total
  | Some keep -> body_height ~total ~keep
