type method_ =
  | Click | Double_click | Drag_and_drop | Mouse_click | Press
  | Keyboard_press | Keyboard_paste | Keyboard_type | Keyboard_insert_text

type t = No_hold | Observed_receipt | Observed_native_window

let contract = function
  | Click | Double_click | Drag_and_drop | Mouse_click | Press
  | Keyboard_press | Keyboard_paste -> Observed_receipt
  | Keyboard_insert_text -> No_hold
  | Keyboard_type -> Observed_native_window

