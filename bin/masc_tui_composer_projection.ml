module Composer = Masc_tui_composer

let source_reading (state : Masc_tui_types.state) : Composer.reading =
  match state.workspace_identity with
    | Workspace_identity_unread -> Composer.Workspace_not_observed
    | Workspace_identity_match_unconfirmed _ -> Composer.Workspace_unconfirmed
    | Workspace_identity_mismatch _ -> Composer.Different_workspace
    | Workspace_identity_match ->
        let status=match state.local_keepers,state.keepers_error with
          | Local_workspace_failed detail,_
          | (Local_workspace_unread | Local_workspace_read),Some detail -> Composer.Read_failed detail
          | Local_workspace_unread,None -> Composer.Not_observed
          | Local_workspace_read,None -> Composer.Observed in
        Composer.Metadata {status;pending=Masc_tui_types.local_source_pending state Local_keepers}

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
        match Masc_tui_types.keeper_message_availability state keeper.k_name with
        | Message_available -> Composer.Ready keeper.k_name
        | Message_unavailable unavailable ->
            let reason=match unavailable with
              | Keeper_missing -> "no longer in the roster"
              | Remote_keeper_observation -> "server observation has no local Keeper metadata"
              | Message_workspace_unobserved -> "server workspace not observed"
              | Message_workspace_unconfirmed -> "server workspace unconfirmed; waiting for the next read"
              | Message_workspace_differs -> "chat needs the server workspace for attachments and pasted files"
              | Keeper_metadata_unobserved -> "Keeper metadata not observed"
              | Keeper_metadata_unavailable _ -> "keeper list unread"
              | Created_keeper_metadata_pending -> "waiting for created Keeper metadata" in
            Composer.Unreachable {keeper=keeper.k_name;reason}
  in
  { Composer.target
  ; reading = source_reading state
  ; focus =
      (if state.composer_focused then Composer.Focused else Composer.Unfocused)
  ; draft = Masc_tui_message_input.contents state.msg_input
  ; staged_images = List.length state.msg_attachments
  }
