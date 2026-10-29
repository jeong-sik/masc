type preference = Adaptive | Expanded
type placement =
  | Full
  | Side of { context_cols : int; queue_cols : int }
  | Bottom of { context_rows : int; queue_rows : int }

let toggle = function Adaptive -> Expanded | Expanded -> Adaptive

let choose preference ~has_context ~cols ~body_rows ~queue_fixed_rows ~queue_item_rows =
  let prose_cols = 2 * Masc_tui_message_layout.chat_min_terminal_cols in
  let context_rows = 1 + 3 in (* Caption and the chat's minimum history window. *)
  let queue_document_rows = queue_fixed_rows + queue_item_rows in
  match preference with
  | Expanded -> Full
  | Adaptive when not has_context -> Full
  | Adaptive when cols < Masc_tui_message_layout.chat_min_terminal_cols -> Full
  | Adaptive when cols >= 2 * prose_cols ->
      let context_cols = cols / 2 in
      Side {context_cols; queue_cols=cols-context_cols}
  | Adaptive when body_rows >= context_rows + 1 + queue_document_rows ->
      Bottom {context_rows; queue_rows=body_rows-context_rows-1}
  | Adaptive -> Full

let queue_rows ~body_rows = function
  | Full | Side _ -> body_rows
  | Bottom {queue_rows; context_rows=_} -> queue_rows

let panes placement ~cols ~first_row ~body_rows =
  let module Pane = Masc_tui_pane_selection in
  let bottom = first_row + body_rows - 1 in
  let pane ~top ~bottom ~left ~right =
    if bottom < top || right < left then []
    else [Pane.{kind=Main; rect={top; bottom; left; right}}] in
  match placement with
  | Full -> pane ~top:(first_row-3) ~bottom:(bottom+2) ~left:1 ~right:cols
  | Side {context_cols; queue_cols=_} ->
      pane ~top:(first_row-3) ~bottom:(bottom+1) ~left:1 ~right:context_cols
      @ pane ~top:(first_row-3) ~bottom:(bottom+1) ~left:(context_cols+1) ~right:cols
      @ pane ~top:(bottom+2) ~bottom:(bottom+2) ~left:1 ~right:cols
  | Bottom {context_rows; queue_rows=_} ->
      pane ~top:(first_row-3) ~bottom:(first_row-1) ~left:1 ~right:cols
      @ pane ~top:first_row ~bottom:(first_row+context_rows-1) ~left:1 ~right:cols
      @ pane ~top:(first_row+context_rows) ~bottom:(first_row+context_rows) ~left:1 ~right:cols
      @ pane ~top:(first_row+context_rows+1) ~bottom:(bottom+2) ~left:1 ~right:cols
