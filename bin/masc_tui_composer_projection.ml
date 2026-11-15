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
        Composer.Metadata {status;pending=Option.map fst (Masc_tui_types.local_source_slow_pending state Local_keepers)}

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
            let say ko en =
              Composer.Keeper_unavailable (Masc_tui_types.ui_text state ~ko ~en) in
            let reason=match unavailable with
              | Keeper_missing -> say "목록에서 사라짐" "no longer in the roster"
              | Remote_keeper_observation ->
                  say "서버 관측에 로컬 키퍼 정보가 없음"
                    "server observation has no local Keeper metadata"
              | Message_workspace_unobserved -> Composer.Workspace_unread
              | Message_workspace_differs -> Composer.Workspace_differs
              | Keeper_metadata_unobserved ->
                  say "키퍼 정보 미조회" "Keeper metadata not observed"
              | Keeper_metadata_unavailable _ ->
                  say "키퍼 목록을 읽지 못함" "keeper list unread"
              | Created_keeper_metadata_pending ->
                  say "새로 만든 키퍼 정보 대기" "waiting for created Keeper metadata" in
            Composer.Unreachable {keeper;reason}

let focus_of_state (state : Masc_tui_types.state) =
  if state.composer_focused then Composer.Focused else Composer.Unfocused

let draft_for_target (state : Masc_tui_types.state) = function
  | Composer.No_target -> "", 0
  | Composer.Ready keeper | Composer.Unreachable {keeper; _} ->
      if state.msg_target_keeper_name = Some keeper then
        Masc_tui_message_input.contents state.msg_input,
        List.length state.msg_attachments
      else
        match List.assoc_opt
            (Masc_tui_types.chat_input_workspace state, keeper) state.msg_drafts with
        | None -> "", 0
        | Some draft -> draft.kcd_text, List.length draft.kcd_attachments

let of_state (state : Masc_tui_types.state) : Composer.t =
  let target = target_of_state state in
  let draft, staged_images = draft_for_target state target in
  { Composer.target
  ; reading = source_reading state
  ; focus = focus_of_state state
  ; draft
  ; staged_images
  }

let classify_key (state : Masc_tui_types.state) key =
  Composer.classify_key ~focus:(focus_of_state state)
    ~target:(fun () -> target_of_state state)
    ~draft:(fun () -> Masc_tui_message_input.contents state.msg_input) key
