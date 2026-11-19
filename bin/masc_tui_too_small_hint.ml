module Viewport = Masc_tui_render_schedule.Viewport

type form =
  | Full
  | Size_and_need
  | Need
  | Need_count
  | Key_only

let quit ~ko = if ko then "q 끝내기" else "q: quit"

let text ~ko ~(have : Viewport.size) ~need_rows form =
  let size = Printf.sprintf "%dx%d" have.cols have.rows in
  let with_quit words = words ^ " · " ^ quit ~ko in
  match form, ko with
  | Full, true -> with_quit (Printf.sprintf "창이 작음 · 지금 %s · %d줄 필요" size need_rows)
  | Full, false ->
      with_quit (Printf.sprintf "terminal too small · now %s · needs %d rows" size need_rows)
  | Size_and_need, true -> with_quit (Printf.sprintf "지금 %s · %d줄 필요" size need_rows)
  | Size_and_need, false -> with_quit (Printf.sprintf "now %s · needs %d rows" size need_rows)
  | Need, true -> with_quit (Printf.sprintf "%d줄 필요" need_rows)
  | Need, false -> with_quit (Printf.sprintf "needs %d rows" need_rows)
  | Need_count, true -> with_quit (Printf.sprintf "%d줄" need_rows)
  | Need_count, false -> with_quit (Printf.sprintf "%d rows" need_rows)
  | Key_only, (true | false) -> quit ~ko

(* Widest first. [Key_only] is not here: it is what is left. *)
let forms_with_count = [ Full; Size_and_need; Need; Need_count ]

let choose ~ko ~cols ~have ~need_rows =
  match
    List.find_opt
      (fun form ->
         Masc_tui_message_layout.display_width (text ~ko ~have ~need_rows form) <= cols)
      forms_with_count
  with
  | Some form -> form
  | None -> Key_only
