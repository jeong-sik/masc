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

type metadata_status = Not_observed | Read_failed of string | Observed
type reading =
  | Workspace_not_observed
  | Workspace_unconfirmed
  | Different_workspace
  | Metadata of
      { status:metadata_status; pending:Masc_tui_local_read_observation.pending option }

type t = {
  target : target;
  reading : reading;
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
   binding cannot be a letter without taking it from typing. A is line-start by
   convention, L is redraw, and C/D/H/I/J/M/Q/S/Z never reach the application.
   On BSD terminals the tty takes Ctrl-Y too, as VDSUSP, until
   [Masc_tui_termios.reclaim] turns that off. *)
let listen_key = "\025"

(* Ctrl-A. The same reasoning as [listen_key]: a focused row spends every
   printable key on draft text. Ctrl-K was the other candidate and is taken —
   it cancels a queued line (masc_tui.ml checks Char.code 11). Board new-post
   compose binds Ctrl-A too, for its attach-file input; the two never meet
   because [text_input_target] gates the composer key path off while board
   compose owns text input. *)
let continuous_key = "\001"

let prompt composer =
  match composer.target with
  | No_target -> "no keeper selected"
  | Unreachable { keeper; reason } -> Printf.sprintf "%s — %s" keeper reason
  | Ready keeper ->
    if composer.staged_images = 0
    then Printf.sprintf "to %s" keeper
    else Printf.sprintf "to %s [%d image]" keeper composer.staged_images

let metadata_step = function
  | Masc_tui_local_read_observation.Awaiting_start -> "starting read"
  | Io_queued -> "waiting to read"
  | Io_running -> "reading metadata"
  | Io_returning -> "receiving result"
  | Preparing | Comparison_queued | Comparison_running | Comparison_returning -> "preparing result"
  | Awaiting_ui -> "result awaiting state application"
  | Masc_tui_local_read_observation.Read_failed Raised -> "read failed"
  | Masc_tui_local_read_observation.Read_failed Interrupted -> "read interrupted"
  | Read_not_started -> "read not started"

let reading_note reading =
  match reading with
  | Workspace_not_observed -> Some "Server workspace not observed"
  | Workspace_unconfirmed -> Some "Server workspace awaiting confirmation"
  | Different_workspace -> Some "Chat needs the server workspace"
  | Metadata {status=Observed;pending=None} -> None
  | Metadata {status=Not_observed;pending=None} -> Some "Keeper list not observed"
  | Metadata {status=Not_observed;pending=Some phase} -> Some ("Keeper list: " ^ metadata_step phase)
  | Metadata {status=Observed;pending=Some phase} -> Some ("Refreshing Keeper list: " ^ metadata_step phase)
  | Metadata {status=Read_failed detail;pending=None} -> Some ("Keeper list unavailable: " ^ detail)
  | Metadata {status=Read_failed detail;pending=Some phase} ->
      Some ("Keeper list: " ^ metadata_step phase ^ " · last read failed: " ^ detail)

let accepts_input composer =
  match (composer.focus, composer.target) with
  | Focused, Ready _ -> true
  | Focused, (No_target | Unreachable _) | Unfocused, _ -> false

let has_draft_text draft = String.trim draft <> ""

let can_send composer =
  match composer.target with
  | No_target | Unreachable _ -> false
  | Ready _ -> has_draft_text composer.draft

(* The key that sends. Named so a caller that has to send without a keypress
   -- a voice capture that ends the sentence itself -- can hand it to
   [classify_key] instead of reaching into the send path directly, which would
   be a second answer to what a draft is. *)
let send_key = "\r"
let is_send_key key = String.equal key send_key

type key_outcome =
  | Take_focus of string
  | Release_focus
  | Send of string
  | Start_listening of string
  | Toggle_continuous of string
  | Edit
  | Pass_to_surface

let classify_key ~focus ~target ~draft key =
  let for_target action fallback =
    match target () with
    | Ready keeper -> action keeper
    | No_target | Unreachable _ -> fallback
  in
  match focus with
  | Unfocused ->
      (* Idle, the row claims one key, and only when pressing it would lead
         somewhere. Claiming more would take letters the surfaces already bind
         to lifecycle and navigation. *)
      if String.equal key focus_key
      then for_target (fun keeper -> Take_focus keeper) Pass_to_surface
      else Pass_to_surface
  | Focused ->
      if String.equal key release_key then Release_focus
      else if String.equal key listen_key
      then
        (* The recipient is what makes a capture worth taking: a transcript
           with nowhere to go is a recording the operator cannot send. *)
        for_target (fun keeper -> Start_listening keeper) Edit
      else if String.equal key continuous_key
      then
        for_target (fun keeper -> Toggle_continuous keeper) Edit
      else if is_send_key key then
        for_target (fun keeper -> if has_draft_text (draft ()) then Send keeper else Edit) Edit
      else Edit

let cursor_column ~prompt_cells ~draft_cells ~terminal_cols =
  let column = prompt_cells + draft_cells + 1 in
  max 1 (min column (max 1 terminal_cols))
