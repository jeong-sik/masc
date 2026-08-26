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

let preview_height ~total ~keep = max 0 (min (total - keep) (total / 2))
let body_height ~total ~keep = max 1 (total - preview_height ~total ~keep)
