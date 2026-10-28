type preference = Adaptive | Expanded
type placement =
  | Full
  | Side of { context_cols : int; queue_cols : int }
  | Bottom of { context_rows : int; queue_rows : int }

let toggle = function Adaptive -> Expanded | Expanded -> Adaptive

let choose preference ~has_context ~cols ~body_rows ~queue_fixed_rows =
  let prose_cols = 2 * Masc_tui_message_layout.chat_min_terminal_cols in
  let context_rows = 1 + 3 in (* Caption and the chat's minimum history window. *)
  let queue_min_rows = queue_fixed_rows + 3 in
  match preference with
  | Expanded -> Full
  | Adaptive when not has_context -> Full
  | Adaptive when cols >= 2 * prose_cols ->
      let context_cols = cols / 2 in
      Side {context_cols; queue_cols=cols-context_cols}
  | Adaptive when body_rows >= context_rows + 1 + queue_min_rows ->
      Bottom {context_rows; queue_rows=body_rows-context_rows-1}
  | Adaptive -> Full

let queue_rows ~body_rows = function
  | Full | Side _ -> body_rows
  | Bottom {queue_rows; context_rows=_} -> queue_rows
