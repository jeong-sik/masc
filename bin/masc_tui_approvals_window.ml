(* The queue's window. The rows the surface leaves it are [body_rows]; a queue
   longer than that draws one row less and spends the freed row on a line that
   says which rows these are. With one row left there is nothing to spend, so
   the window keeps its row and [hides_rows] tells the row to carry its own
   position instead. *)
let overflows ~body_rows ~total = body_rows > 1 && total > body_rows
let hides_rows ~body_rows ~total = total > body_rows
let rows ~body_rows ~total = if overflows ~body_rows ~total then body_rows - 1 else body_rows

(* Where the window stands and how to reach the rest: the window text every
   scrolled list on this screen uses, and how many rows lie each way. *)
let note ~scroll ~height ~total =
  let above = max 0 scroll in
  let below = max 0 (total - (scroll + height)) in
  let reach =
    match above, below with
    | 0, 0 -> ""
    | above, 0 -> Printf.sprintf "%d more above" above
    | 0, below -> Printf.sprintf "%d more below" below
    | above, below -> Printf.sprintf "%d above \xc2\xb7 %d below" above below
  in
  Printf.sprintf
    "[approvals %s]  %s -- j/k to reach"
    (Masc_tui_scroll.window_text ~scroll ~height total)
    reach
;;
