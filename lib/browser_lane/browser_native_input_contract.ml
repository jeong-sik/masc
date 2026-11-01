type method_ =
  | Click | Double_click | Drag_and_drop | Mouse_click | Press
  | Keyboard_press | Keyboard_paste | Keyboard_type | Keyboard_insert_text
  | Raw_pointer_drag

type unavailable = Keyboard_type_void | Raw_pointer_drag_void
type t = No_hold | Observed_receipt | Unattestable_raw_hold of unavailable

let contract = function
  | Click | Double_click | Drag_and_drop | Mouse_click | Press
  | Keyboard_press | Keyboard_paste -> Observed_receipt
  | Keyboard_insert_text -> No_hold
  | Keyboard_type -> Unattestable_raw_hold Keyboard_type_void
  | Raw_pointer_drag -> Unattestable_raw_hold Raw_pointer_drag_void

let unavailable = function
  | No_hold | Observed_receipt -> None
  | Unattestable_raw_hold reason -> Some reason

let message = function
  | Keyboard_type_void ->
      "Native keyboard.type is unavailable: its void return can also hide a dialog-interrupted key sequence. It is refused before input. For new work explicitly choose native fill to replace an observed field/editor, keyboard.insertText for literal insertion at the observed focus, or keyboard.paste for text/HTML. Never replay uncertain input."
  | Raw_pointer_drag_void ->
      "Native raw pointer drag is unavailable: mouse.down/move/up have no release receipt. Coordinate, waypoint and scene-node drags are refused before input. Explicitly choose selector-to-selector drag_to without via, or native workflow dragAndDrop; inspect application acceptance afterward. Never replay uncertain input."
