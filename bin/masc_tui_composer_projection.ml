module Composer = Masc_tui_composer

(* The recipient is whichever keeper the roster cursor points at. That cursor
   keeps its place while the operator works on another surface, so the row goes
   on naming the last keeper they pointed at rather than emptying out. Because
   the cursor can also move on its own -- a refresh drops a row and the one
   below slides up -- every consumer takes this fresh projection instead of
   capturing a recipient beside the draft. *)
let of_state (state : Masc_tui_types.state) : Composer.t =
  let target =
    match Masc_tui_types.selected_keeper state with
    | None -> Composer.No_target
    | Some keeper ->
        if
          Masc_tui_types.keeper_available_for_new_message state keeper.k_name
        then Composer.Ready keeper.k_name
        else
          Composer.Unreachable
            { keeper = keeper.k_name
            ; reason =
                (match state.keepers_error with
                 | Some _ -> "keeper list unread"
                 | None -> "no longer in the roster")
            }
  in
  { Composer.target
  ; focus =
      (if state.composer_focused then Composer.Focused else Composer.Unfocused)
  ; draft = Buffer.contents state.msg_input
  ; staged_images = List.length state.msg_attachments
  }
