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

(* Taking focus binds the existing message target. A refreshed roster cursor
   is navigation, not permission to retarget that draft. Availability is still
   read afresh for the bound name, including when its row has disappeared. *)
let target_of_state (state : Masc_tui_types.state) =
  let recipient =
    if Masc_tui_types.composer_is_live state then state.msg_target_keeper_name
    else Option.map (fun (keeper : Masc_tui_types.keeper) -> keeper.k_name)
      (Masc_tui_types.selected_keeper state)
  in
    match recipient with
    | None -> Composer.No_target
    | Some keeper ->
        match Masc_tui_types.keeper_message_availability state keeper with
        | Message_available -> Composer.Ready keeper
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
            Composer.Unreachable {keeper;reason}

let focus_of_state (state : Masc_tui_types.state) =
  if state.composer_focused then Composer.Focused else Composer.Unfocused

let of_state (state : Masc_tui_types.state) : Composer.t =
  { Composer.target = target_of_state state
  ; reading = source_reading state
  ; focus = focus_of_state state
  ; draft = Masc_tui_message_input.contents state.msg_input
  ; staged_images = List.length state.msg_attachments
  }

let classify_key (state : Masc_tui_types.state) key =
  Composer.classify_key ~focus:(focus_of_state state)
    ~target:(fun () -> target_of_state state)
    ~draft:(fun () -> Masc_tui_message_input.contents state.msg_input) key
