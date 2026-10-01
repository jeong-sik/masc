(** Board response application and draft/vote completion transitions. *)

open Masc_tui_types

module Board_detail = Masc_tui_board_detail
module Board_selection = Masc_tui_board_selection

let replace_board_posts state posts =
  let source =
    match state.board_mode with
    | Board_list | Board_compose -> Board_selection.List_cursor
    | Board_read post_id -> Board_selection.Detail_post post_id
  in
  let post_ids posts = List.map (fun post -> post.bp_id) posts in
  let cursor =
    Board_selection.reconcile_cursor
      ~current_ids:(post_ids state.board_posts)
      ~cursor:state.board_cursor ~source ~next_ids:(post_ids posts)
  in
  state.board_posts <- posts;
  state.board_cursor <- cursor

let leave_board_detail state =
  state.board_mode <- Board_list;
  state.board_focus <- Right_pane;
  state.board_scroll <- 0;
  state.board_comment_scroll <- 0;
  state.board_comment_landing <- None;
  state.board_comments_focused <- false;
  state.board_history_post_id <- None;
  state.board_detail <- Board_detail.clear state.board_detail

let apply_board_hearths_load state = function
  | Ok census -> state.board_hearths <- census
  | Error _ ->
      (* The census is what [f] walks. A failed read keeps the last one rather
         than emptying it: a cycle that has gone quiet because one request
         failed is worse than a cycle one refresh out of date. *)
      ()

let apply_board_list_load state ~remember_error = function
  | Ok posts ->
      replace_board_posts state posts;
      state.board_list_reading <- Board_list_read;
      (* A sorted/filtered page cannot establish that an exact-ID target
         disappeared. Its own detail request owns loading and failure, even
         when the recent page is empty or excludes this historical post. *)
      state.board_list_error <- None
  | Error err ->
      remember_error err

let board_detail_request_still_current state request =
  Board_detail.is_current state.board_detail request
  &&
  match state.board_mode with
  | Board_read post_id ->
      String.equal post_id (Board_detail.request_post_id request)
  | Board_list | Board_compose -> false

let apply_board_post_load state ~report_error request result =
  if board_detail_request_still_current state request then
    let post_id = Board_detail.request_post_id request in
    let fail err =
      let err = "Board post load failed: " ^ err in
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
        state.board_posts <-
          List.map
            (fun current ->
              if String.equal current.bp_id post_id then post else current)
            state.board_posts
    | Ok (post, _, _) ->
        fail
          (Printf.sprintf
             "response ID mismatch: expected %s, received %s"
             post_id post.bp_id)
    | Error err -> fail err

let new_post_done state ~reply_to ~sent_draft ~report ~refresh ~refresh_detail result =
  (* The completion answers for the draft it carried, not for whatever
     is in the buffer now: a slow server must not clear words typed
     since, nor yank the operator out of a compose they restarted. *)
  state.board_post_inflight <- false;
  let compose_unchanged =
    String.equal (Buffer.contents state.board_draft) sent_draft
  in
  match result with
  | Ok message ->
      report "system" ("Board: " ^ message);
      if compose_unchanged then begin
        Buffer.clear state.board_draft;
        state.board_compose_armed <- false;
        state.board_compose_reply_to <- None;
        state.board_compose_hearth <- None;
        state.board_post_error <- None;
        match reply_to with
        | Some post_id -> state.board_mode <- Board_read post_id
        | None -> state.board_mode <- Board_list
      end;
      (* The posted row is the half the periodic refresh has not fetched
         yet; without this the operator returns to a list that does not
         contain what they just published. A comment refreshes the
         detail too, so the reply is visible the moment it lands. *)
      refresh ();
      (match reply_to with
       | Some post_id ->
           refresh_detail post_id
       | None -> ())
  | Error err ->
      state.board_compose_armed <- false;
      (* The draft stays: a rejected post is usually one field short, and
         losing the text over it would make the error a dead end. *)
      state.board_post_error <- Some err

let vote_done state ~report ~refresh result =
  match result with
  | Ok message ->
      state.board_vote_armed <- None;
      report "system" ("Board vote: " ^ message);
      (* The score is drawn from the list; refresh it rather than
         waiting out the interval to see the arrow land. *)
      refresh ()
  | Error err ->
      state.board_vote_armed <- None;
      report "error" ("Board vote failed: " ^ err)
