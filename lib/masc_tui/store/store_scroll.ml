let default_viewport_rows = 15

let clamp_index len idx =
  if len <= 0 then 0
  else if idx < 0 then 0
  else if idx >= len then len - 1
  else idx

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
  else if vis_row >= scroll + vr then max 0 (vis_row - vr + 1)
  else scroll

let clamp_scroll ?max_scroll offset =
  let non_neg = max 0 offset in
  match max_scroll with
  | None -> non_neg
  | Some hi -> min (max 0 hi) non_neg

let contains_ci ~needle haystack =
  let n_len = String.length needle in
  if n_len = 0 then true
  else
    let h_len = String.length haystack in
    if n_len > h_len then false
    else
      let n_low = String.lowercase_ascii needle in
      let h_low = String.lowercase_ascii haystack in
      let limit = h_len - n_len in
      let rec scan i =
        if i > limit then false
        else if String.equal (String.sub h_low i n_len) n_low then true
        else scan (i + 1)
      in
      scan 0

let rec drop n xs =
  if n <= 0 then xs
  else match xs with [] -> [] | _ :: tl -> drop (n - 1) tl
