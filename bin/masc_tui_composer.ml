type target =
  | No_target
  | Unreachable of {
      keeper : string;
      reason : string;
    }
  | Ready of string

type focus =
  | Unfocused
  | Focused

type t = {
  target : target;
  focus : focus;
  draft : string;
  staged_images : int;
}

(* One row, and only where the surface above can still meet its own fixed-row
   budget without it. *)
let rows_for ~terminal_rows =
  if terminal_rows > Masc_tui_render_schedule.Viewport.minimum_fixed_chrome_rows
  then 1
  else 0

let focus_key = "i"
let release_key = "esc"

(* Ctrl-Y. Every printable key in a focused row is draft text, so a voice
   binding cannot be a letter without taking it from typing. Ctrl-Y is the one
   control code this TUI does not already spend: A is line-start by convention,
   L is redraw, and C/D/H/I/J/M/Q/S/Z never reach the application. *)
let listen_key = "\025"

let prompt composer =
  match composer.target with
  | No_target -> "no keeper selected"
  | Unreachable { keeper; reason } -> Printf.sprintf "%s — %s" keeper reason
  | Ready keeper ->
    if composer.staged_images = 0
    then Printf.sprintf "to %s" keeper
    else Printf.sprintf "to %s [%d image]" keeper composer.staged_images

let accepts_input composer =
  match (composer.focus, composer.target) with
  | Focused, Ready _ -> true
  | Focused, (No_target | Unreachable _) | Unfocused, _ -> false

let can_send composer =
  match composer.target with
  | No_target | Unreachable _ -> false
  | Ready _ -> String.trim composer.draft <> ""

let is_send_key key = String.equal key "\r"

type key_outcome =
  | Take_focus
  | Release_focus
  | Send
  | Start_listening
  | Edit
  | Pass_to_surface

let classify_key composer key =
  match composer.focus with
  | Unfocused ->
      (* Idle, the row claims one key, and only when pressing it would lead
         somewhere. Claiming more would take letters the surfaces already bind
         to lifecycle and navigation. *)
      if String.equal key focus_key && accepts_input { composer with focus = Focused }
      then Take_focus
      else Pass_to_surface
  | Focused ->
      if String.equal key release_key then Release_focus
      else if String.equal key listen_key
      then
        (* The recipient is what makes a capture worth taking: a transcript
           with nowhere to go is a recording the operator cannot send. *)
        (if can_send { composer with draft = "x" } then Start_listening else Edit)
      else if is_send_key key then if can_send composer then Send else Edit
      else Edit

let cursor_column ~prompt_cells ~draft_cells ~terminal_cols =
  let column = prompt_cells + draft_cells + 1 in
  max 1 (min column (max 1 terminal_cols))
