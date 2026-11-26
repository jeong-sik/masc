let default_viewport_rows = 15

let clamp_index = Masc_tui_core.Text_util.clamp_index

let adjust_scroll ?(viewport_rows = default_viewport_rows) ~scroll selected =
  let vr = max 1 viewport_rows in
  if selected < scroll then selected
  else if selected >= scroll + vr then max 0 (selected - vr + 1)
  else scroll

let adjust_grouped_scroll ?(viewport_rows = default_viewport_rows) ~scroll
    ~header_row vis_row =
  let vr = max 1 viewport_rows in
  let top_row = if vr >= 2 then min header_row vis_row else vis_row in
  if top_row < scroll then top_row
  else if vis_row >= scroll + vr then
    let needed = max 0 (vis_row - vr + 1) in
    min top_row needed
  else scroll

let clamp_scroll ?max_scroll offset =
  let non_neg = max 0 offset in
  match max_scroll with
  | None -> non_neg
  | Some hi -> min (max 0 hi) non_neg

let contains_ci = Masc_tui_core.Text_util.contains_ci

let rec drop n xs =
  if n <= 0 then xs
  else match xs with [] -> [] | _ :: tl -> drop (n - 1) tl
