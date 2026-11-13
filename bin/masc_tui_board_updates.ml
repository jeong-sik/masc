(** Board response application and draft/vote completion transitions. *)

open Masc_tui_types

module Board_detail = Masc_tui_board_detail

let leave_board_detail state =
  state.board_mode <- Board_list;
  state.board_focus <- Right_pane;
  state.board_scroll <- 0;
  state.board_comment_scroll <- 0;
  state.board_comment_landing <- None;
  state.board_comments_focused <- false;
  state.board_history_post_id <- None;
  state.board_detail <- Board_detail.clear state.board_detail

let board_detail_request_still_current state request =
  Board_detail.is_current state.board_detail request
  &&
  match state.board_mode with
  | Board_read post_id ->
      String.equal post_id (Board_detail.request_post_id request)
  | Board_compose ->
      Option.equal String.equal state.board_compose_reply_to
        (Some (Board_detail.request_post_id request))
  | Board_list -> false

let apply_board_post_load state ~report_error request result =
  if board_detail_request_still_current state request then
    let post_id = Board_detail.request_post_id request in
    let fail err =
      let ko = state.ui_language = Lang_ko in
      let err = (if ko then "글 " else "Board post ") ^ field_failed ~ko ^ ": " ^ err in
      state.board_detail <-
        Board_detail.complete state.board_detail request (Error err);
      if state.view <> Board then
        report_error err
    in
    let initial_read =
      match Board_detail.view_for state.board_detail ~post_id with
      | Board_detail.Loading | Board_detail.Failed _ -> true
      | Board_detail.Absent | Board_detail.Ready _ -> false in
    match result with
    | Ok (post, comments, landing) when String.equal post.bp_id post_id ->
        state.board_detail <-
          Board_detail.complete state.board_detail request (Ok (post, comments, landing));
        if initial_read then state.board_comment_landing <- landing;
        (* A detail response enriches one list row; it does not rank the list.
           Moving the completed post to the front made rapid j/k navigation
           snap back to row zero as asynchronous responses arrived. *)
        enrich_board_list_post state post
    | Ok (post, _, _) ->
        fail
          (Printf.sprintf
             (if state.ui_language = Lang_ko then "응답 글 ID 다름 · 요청 %s · 받음 %s"
              else "response ID mismatch · expected %s · received %s")
             post_id post.bp_id)
    | Error err -> fail err

module Publication = Masc_tui_board_publication

let publication_diagnostic ~ko = function
  | Publication.Not_attempted { detail; _ } ->
      (if ko then "글 " else "Board post ") ^ not_sent ~ko ^ ": " ^ detail
  | Publication.Returned { response; _ } ->
      let detail = Option.value (Publication.response_diagnostic ~ko response)
          ~default:(if ko then "응답 없음" else "no acknowledgement received") in
      match Publication.response_effect response with
      | Failure_effect.Proven_pre_effect ->
          (if ko then "게시판이 글을 거절함: " else "Board refused the post: ") ^ detail
      | Failure_effect.Effect_outcome_unknown ->
          Publication.outcome_unknown ~ko ^ ": " ^ detail
      | Failure_effect.Proven_post_effect -> detail

let apply_current_publication state ~report ~refresh outcome request =
  state.board_write <- Board_idle;
  let ko = state.ui_language = Lang_ko in
  let committed_post_id = match outcome with
    | Publication.Not_attempted _ -> None
    | Publication.Returned { response; _ } -> Publication.committed_post_id response in
  match committed_post_id with
  | Some post_id ->
      let post_id = Board_types.Post_id.to_string post_id in
      let diagnostic = match outcome with
        | Publication.Not_attempted _ -> None
        | Publication.Returned { response; _ } -> Publication.response_diagnostic ~ko response in
      state.board_compose_attachments <-
        List.filter (fun staged -> not (List.memq staged request.Publication.staged))
          state.board_compose_attachments;
      if String.equal (Buffer.contents state.board_draft) request.sent_draft then begin
        Buffer.clear state.board_draft;
        state.board_compose_armed <- false;
        state.board_compose_reply_to <- None;
        state.board_compose_hearth <- None;
        state.board_compose_attach_input <- None;
        state.board_mode <- Board_list
      end;
      let published =
        if ko then "글 " ^ post_id ^ " 올림" else "Board post " ^ post_id ^ " published" in
      state.board_post_error <- Option.map (fun detail -> published ^ " · " ^ detail) diagnostic;
      report "system"
        (published ^ Option.fold ~none:"" ~some:(fun detail -> " · " ^ detail) diagnostic);
      refresh ()
  | None ->
      state.board_compose_armed <- false;
      state.board_post_error <- Some (publication_diagnostic ~ko outcome)

let apply_publication state ~report ~refresh outcome =
  match Publication.record state.board_publications outcome with
  | Publication.Already_recorded | Publication.Not_registered -> ()
  | Publication.Recorded history ->
      (* The receipt belongs to its original request even after workspace
         withdrawal. Retain it before admission or caller-owned callbacks. *)
      state.board_publications <- history;
      let request = Publication.outcome_request outcome in
      let current = match state.board_write with
        | Board_posting current -> Publication.same_request current request
        | Board_idle | Board_commenting _ -> false in
      if current && workspace_reply_admitted state ~authority:request.authority
          ~reading:None ~kind:Workspace_operation_outcome then
        apply_current_publication state ~report ~refresh outcome request

let comment_outcome_unknown ~ko =
  if ko then "댓글 결과 미확인 · 다시 보내기 전에 댓글을 확인하세요"
  else "Board comment outcome unknown · check the thread before retrying"

let comment_launch_failed state ~request_id =
  match state.board_write with
  | Board_commenting current when current == request_id ->
    state.board_write <- Board_idle;
    state.board_compose_armed <- false;
    state.board_post_error <- Some (comment_outcome_unknown ~ko:(state.ui_language = Lang_ko))
  | Board_idle | Board_posting _ | Board_commenting _ -> ()

let comment_done state ~request_id ~post_id ~sent_draft ~report ~refresh ~refresh_detail result =
  match state.board_write with
  | Board_commenting current when current == request_id ->
    state.board_write <- Board_idle;
    (match result with
    | Ok message ->
        if String.equal (Buffer.contents state.board_draft) sent_draft then begin
          Buffer.clear state.board_draft;
          state.board_compose_armed <- false;
          state.board_compose_reply_to <- None;
          state.board_compose_hearth <- None;
          state.board_post_error <- None;
          state.board_compose_attach_input <- None;
          state.board_mode <- Board_read post_id
        end;
        report "system" ((if state.ui_language = Lang_ko then "게시판: " else "Board: ") ^ message);
        refresh ();
        refresh_detail post_id
    | Error err ->
        state.board_compose_armed <- false;
        state.board_post_error <- Some err)
  | Board_idle | Board_posting _ | Board_commenting _ -> ()

let vote_done state ~report ~refresh ~refresh_detail target result =
  match result with
  | Ok message ->
      state.board_vote_armed <- None;
      report "system" ((if state.ui_language = Lang_ko then "투표: " else "Board vote: ") ^ message);
      (* The list row draws a post's score and the open reading draws the
         post header and every comment's; refresh both rather than waiting
         out the interval to see the arrow land. The comment cursor is an
         id, so the refreshed thread keeps it on the comment just voted. *)
      refresh ();
      let voted_post = Masc_tui_board_vote.post_id target in
      (match state.board_mode with
       | Board_read open_post when String.equal open_post voted_post ->
           refresh_detail voted_post
       | Board_read _ | Board_list | Board_compose -> ())
  | Error err ->
      state.board_vote_armed <- None;
      report "error" ((if state.ui_language = Lang_ko then "투표 실패: " else "Board vote failed: ") ^ err)
