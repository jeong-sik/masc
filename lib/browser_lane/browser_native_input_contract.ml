type method_ =
  | Click | Double_click | Drag_and_drop | Mouse_click | Press
  | Keyboard_press | Keyboard_paste | Keyboard_type | Keyboard_insert_text
  | Raw_pointer_drag

type unavailable = Raw_pointer_drag_void
type t = No_hold | Observed_receipt | Observed_native_window | Unattestable_raw_hold of unavailable

let contract = function
  | Click | Double_click | Drag_and_drop | Mouse_click | Press
  | Keyboard_press | Keyboard_paste -> Observed_receipt
  | Keyboard_insert_text -> No_hold
  | Keyboard_type -> Observed_native_window
  | Raw_pointer_drag -> Unattestable_raw_hold Raw_pointer_drag_void

let unavailable = function
  | No_hold | Observed_receipt | Observed_native_window -> None
  | Unattestable_raw_hold reason -> Some reason

let message = function
  | Raw_pointer_drag_void ->
      "Native raw pointer drag is unavailable: mouse.down/move/up have no release receipt. Coordinate, waypoint and scene-node drags are refused before input. Explicitly choose selector-to-selector drag_to without via, or native workflow dragAndDrop; inspect application acceptance afterward. Never replay uncertain input."
