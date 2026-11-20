type preference = Hidden | Shown

let effective_hidden preference =
  match preference with
  | Hidden -> true
  | Shown -> false

let threshold_cols = 110
(* A 30-cell pane left 23 cells for the name after the border, health mark,
   and spacing. That cut ordinary configured names such as
   [pinewood-pr-jira-checker] even on a 173-column terminal, while the chat
   beside it still had more than 130 cells. Four more cells keep that name
   whole and remain a bounded, stable split: resizing still changes message
   wrapping only when the pane itself appears or disappears. *)
let pane_cols = 34

let shown ~hidden ~cols = (not hidden) && cols >= threshold_cols

let toggle_hidden ~hidden ~cols =
  if cols < threshold_cols then None else Some (not hidden)

let toggle_preference preference ~cols =
  toggle_hidden ~hidden:(effective_hidden preference) ~cols
  |> Option.map (fun hidden -> if hidden then Hidden else Shown)

let content_cols ~hidden ~cols =
  if shown ~hidden ~cols then cols - pane_cols else cols

(* A pane that is not drawn cannot hold a keypress.

   Focus beside the detail is a stored preference, and on its own it is not
   the answer: the reader can put the roster away with Ctrl-B, and the
   terminal can be too narrow to draw it. Either way the detail is the only
   pane on screen. Trusting the preference sent arrows to a cursor nobody
   could see -- and with the selection already at the end of the roster,
   moved nothing at all, which reads as a dead key. *)
let arrows_go_left ~hidden ~cols ~preferring_left =
  preferring_left && shown ~hidden ~cols

type zoom =
  | Normal
  | Half
  | Full

let zoom_in = function
  | Normal -> Half
  | Half | Full -> Full

let zoom_out = function
  | Full -> Half
  | Half | Normal -> Normal

let step_zoom ~zoom ~direction ~activity_available ~roster_available =
  match direction with
  | `In -> (
      if not activity_available && not roster_available then None
      else
        match zoom with
        | Normal ->
            if activity_available then Some Half
            else Some Full
        | Half ->
            if roster_available then Some Full
            else Some Half
        | Full -> Some Full)
  | `Out -> (
      match zoom with
      | Full -> if activity_available then Some Half else Some Normal
      | Half | Normal -> Some Normal)

let hides_activity = function
  | Normal -> false
  | Half | Full -> true

let hides_roster = function
  | Normal | Half -> false
  | Full -> true

let zoom_label ~ko = function
  | Normal -> if ko then "화면 분할: 기본 (Normal)" else "Pane zoom: normal"
  | Half -> if ko then "화면 분할: 넓게 (Half · 우측 패널 접음)" else "Pane zoom: half (Activity hidden)"
  | Full -> if ko then "화면 분할: 전체 (Full · 좌우 패널 접음)" else "Pane zoom: full (side panes hidden)"
