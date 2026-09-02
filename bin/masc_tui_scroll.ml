let maximum ~count ~height = max 0 (count - height)

let normalize ~count ~height scroll =
  max 0 (min scroll (maximum ~count ~height))

let down ~count ~height scroll =
  min (maximum ~count ~height) (normalize ~count ~height scroll + 1)

let up ~count ~height scroll = max 0 (normalize ~count ~height scroll - 1)

(* Not in the interface: [cursor_down] and [cursor_up] are the only callers,
   and an exported clamp with no caller is a surface the ratchet counts. *)
let cursor_normalized ~count cursor = max 0 (min cursor (count - 1))

let cursor_down ~count cursor =
  min (max 0 (count - 1)) (cursor_normalized ~count cursor + 1)

let cursor_up ~count cursor = max 0 (cursor_normalized ~count cursor - 1)

let ensure_visible ~cursor ~height scroll =
  if cursor < scroll then cursor
  else if cursor > scroll + height - 1 then cursor - height + 1
  else max 0 scroll

(* [ensure_visible] answers a row that fell below the fold by pinning it to
   the window's last line. That answer assumes nothing lives under the row.
   On a surface whose detail column begins on the selected row's own line and
   runs downward, the bottom pin holds that detail behind the last line for
   good: the keys there move the cursor, and every move re-pins the next row
   to the same edge. When the window has to move at all, lead it from [lead]
   lines above the row -- the detail column's header, on the pane that needs
   this -- so the row and the content under it fill the window. A window too
   short to spend the lead above the row keeps the row on its last line
   instead: that is [ensure_visible]'s placement, and it still shows the
   row. *)
let ensure_leading ~cursor ~lead ~height scroll =
  let followed = ensure_visible ~cursor ~height scroll in
  if followed = scroll then followed
  else max (cursor - height + 1) (max 0 (cursor - lead))

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
