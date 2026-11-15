type unreachable =
  | Workspace_unread
  | Workspace_differs
  | Keeper_unavailable of string

type target =
  | No_target
  | Unreachable of {
      keeper : string;
      reason : unreachable;
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

(* The workspace gate is said in the words the top row and the footer use. A
   mismatch adds why chat needs the matching workspace at all. *)
let unreachable_text ~ko = function
  | Workspace_unread -> Masc_tui_words.workspace_identity_unread ~ko
  | Workspace_differs ->
      Masc_tui_words.workspace_mismatch ~ko ^ " · "
      ^ if ko then "첨부와 붙여 넣은 파일 때문에 채팅은 같은 워크스페이스가 필요함"
        else "chat needs a matching workspace for attachments and pasted files"
  | Keeper_unavailable reason -> reason

let prompt ~ko composer =
  match composer.target with
  | No_target -> if ko then "고른 키퍼 없음" else "no keeper selected"
  | Unreachable { keeper; reason } ->
      Printf.sprintf "%s — %s" keeper (unreachable_text ~ko reason)
  | Ready keeper ->
    let recipient = if ko then keeper ^ " 에게" else "to " ^ keeper in
    if composer.staged_images = 0
    then recipient
    else
      Printf.sprintf "%s [%s]" recipient
        (Masc_tui_value.Count.reading ~ko Masc_tui_value.Count.Image
           composer.staged_images)

let metadata_step ~ko phase =
  let say korean english = if ko then korean else english in
  match phase with
  | Masc_tui_local_read_observation.Awaiting_start -> say "조회 시작 중" "starting read"
  | Io_queued -> say "조회 대기" "waiting to read"
  | Io_running -> say "조회 중" "reading metadata"
  | Io_returning -> say "결과 받는 중" "receiving result"
  | Preparing | Comparison_queued | Comparison_running | Comparison_returning ->
      say "결과 준비 중" "preparing result"
  | Awaiting_ui -> say "결과 반영 대기" "result awaiting state application"
  | Masc_tui_local_read_observation.Read_failed Raised -> say "조회 실패" "read failed"
  | Masc_tui_local_read_observation.Read_failed Interrupted -> say "조회 중단" "read interrupted"
  | Read_not_started -> say "조회 시작 안 함" "read not started"

let reading_note ~ko reading =
  let say korean english = if ko then korean else english in
  let sentence word = String.capitalize_ascii (word ~ko) in
  match reading with
  | Workspace_not_observed -> Some (sentence Masc_tui_words.workspace_identity_unread)
  | Workspace_unconfirmed -> Some (sentence Masc_tui_words.workspace_identity_unconfirmed)
  | Different_workspace -> Some (sentence Masc_tui_words.workspace_mismatch)
  | Metadata {status=Observed;pending=None} -> None
  | Metadata {status=Not_observed;pending=None} ->
      Some (say "키퍼 목록 미조회" "Keeper list not observed")
  | Metadata {status=Not_observed;pending=Some phase} ->
      Some (say "키퍼 목록: " "Keeper list: " ^ metadata_step ~ko phase)
  | Metadata {status=Observed;pending=Some phase} ->
      Some (say "키퍼 목록 새로 조회: " "Refreshing Keeper list: " ^ metadata_step ~ko phase)
  | Metadata {status=Read_failed detail;pending=None} ->
      Some (say "키퍼 목록 조회 실패: " "Keeper list unavailable: " ^ detail)
  | Metadata {status=Read_failed detail;pending=Some phase} ->
      Some
        (say "키퍼 목록: " "Keeper list: " ^ metadata_step ~ko phase
         ^ say " · 지난 조회 실패: " " · last read failed: " ^ detail)

(* The prompt of a target the workspace gate withheld already names the
   workspace state, which is the reading too: both come from one identity. *)
let row_note ~ko composer =
  match composer.target with
  | Unreachable { reason = Workspace_unread | Workspace_differs; _ } -> None
  | No_target | Ready _ | Unreachable { reason = Keeper_unavailable _; _ } ->
      reading_note ~ko composer.reading

let accepts_input composer =
  match (composer.focus, composer.target) with
  | Focused, Ready _ -> true
  | Focused, (No_target | Unreachable _) | Unfocused, _ -> false

let has_draft_text draft = String.trim draft <> ""

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
