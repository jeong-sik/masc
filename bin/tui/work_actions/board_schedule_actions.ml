module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Board_detail = Masc_tui_board_detail
module Kept_request = Masc_tui_words.Kept_request

let schedule_detail_on_screen (state : T.state) =
  match state.T.schedule_detail_id, state.T.schedules with
  | Some id, Some snapshot ->
      List.find_opt (fun row -> String.equal row.T.sch_schedule_id id) snapshot.T.scs_rows
  | Some _, None | None, _ -> None

(* The open post's comment ids in drawn order and the comment its read
   landed on, while its thread is on screen. *)
let board_read_thread (state : T.state) ~post_id =
  match Board_detail.view_for state.T.board_detail ~post_id with
  | Board_detail.Ready (_, comments, landing) ->
      Some (Masc_tui_board_comment_cursor.ordered_ids comments, landing)
  | Board_detail.Absent | Board_detail.Loading | Board_detail.Failed _ -> None

(* Settle the comment cursor on a drawn comment and ask the next frame to
   bring it on screen: focusing the comments, and the first vote press on
   one, should show the comment the keys act on. [None] while no thread is
   drawn. *)
let select_board_comment state ~post_id =
  match board_read_thread state ~post_id with
  | None -> None
  | Some (ids, landing) ->
      let selected =
        Masc_tui_board_comment_cursor.select ids ~landing
          state.T.board_comment_cursor
      in
      state.T.board_comment_cursor <- selected;
      state.T.board_comment_follow <- true;
      selected

(* The kind decides the route: a post vote and a comment vote are two
   requests, and nothing here can send one as the other. *)
let send_board_vote (state : T.state) ~mailbox ~(up : bool) target =
  let launch ~deliver read =
    Masc_tui_transport.Workspace_admission.launch_guarded_request state ~mailbox
      ~boundary_error:(fun detail -> T.Request_failed detail)
      ~withdrawn:(fun refusal -> T.Request_withdrawn refusal) ~deliver read in
  let report = Masc_tui_loader.report_action state in
  match target with
  | T.Vote_post post_id ->
      Masc_tui_board_requests.start_board_vote state ~host:Masc_tui_transport.Workspace_admission.server_peer_host
        ~report ~launch ~post_id ~up
  | T.Vote_comment { post_id; comment_id } ->
      Masc_tui_board_requests.start_board_comment_vote state
        ~host:Masc_tui_transport.Workspace_admission.server_peer_host ~report ~launch ~post_id ~comment_id ~up

(* The vote keys. On the list they vote on the row under the cursor; while
   reading, on the selected comment when the comments have focus and on the
   open post otherwise. Two presses: the first names the target and
   direction, the same press again sends it. The target is captured at arm
   time, kind included, so moving the cursor between presses re-arms for
   the new target rather than voting on the one the operator left. *)
let handle_board_vote_key (state : T.state) ~cols ~mailbox ~(up : bool) =
  let target =
    match state.T.board_mode with
    | T.Board_list ->
        Option.map
          (fun (post : T.board_post) -> T.Vote_post post.T.bp_id)
          (List.nth_opt (T.board_posts state) state.T.board_cursor)
    | T.Board_read post_id
      when T.board_read_focus state ~cols = T.Right_pane
           && state.T.board_comments_focused ->
        Option.map
          (fun comment_id -> T.Vote_comment { post_id; comment_id })
          (select_board_comment state ~post_id)
    | T.Board_read post_id -> Some (T.Vote_post post_id)
    | T.Board_compose -> None
  in
  match target with
  | None -> ()
  | Some target -> (
      match Masc_tui_board_vote.press ~armed:state.T.board_vote_armed ~target ~up with
      | Masc_tui_board_vote.Send (target, up) ->
          state.T.board_vote_armed <- None;
          send_board_vote state ~mailbox ~up target
      | Masc_tui_board_vote.Arm (target, up) ->
          state.T.board_vote_armed <- Some (target, up);
          let ko = state.T.ui_language = T.Lang_ko in
          let key = if up then "v" else "V" in
          let direction = Masc_tui_board_vote.direction ~ko ~up in
          let target_text = Masc_tui_board_vote.describe ~ko target in
          Masc_tui_loader.report_action state "system"
            (if ko then Printf.sprintf "%s 한 번 더 누르면 %s %s" key target_text direction
             else Printf.sprintf "press %s again to vote %s on %s" key direction target_text))

(* Cancel a schedule through the tools route. Same fiber-and-mailbox shape as
   the other writes; the server's store rules decide whether the row is still
   cancellable, so the TUI does not pre-guess from the status column. *)
let start_schedule_cancel (state : T.state) ~mailbox ~(schedule_id : string) =
  match state.T.workspace_identity with
  | T.Workspace_identity_unread ->
      Masc_tui_transport.Request_notice.report_kept_back state ~request:Kept_request.Schedule_cancel Masc_tui_words.workspace_identity_unread Masc_tui_words.Nothing_kept
  | T.Workspace_identity_match_unconfirmed _ ->
      Masc_tui_transport.Request_notice.report_kept_back state ~request:Kept_request.Schedule_cancel Masc_tui_words.workspace_identity_unconfirmed Masc_tui_words.Nothing_kept
  | T.Workspace_identity_match | T.Workspace_identity_mismatch _ ->
  let enqueue_async = Masc_tui_transport.Workspace_admission.workspace_enqueue state in
  let admit = Masc_tui_transport.Workspace_admission.capture_admission state ~mailbox in
  state.T.schedule_cancel_error <- None;
  Masc_tui_loader.report_action state "system"
    (if state.T.ui_language = T.Lang_ko then Printf.sprintf "일정 %s 취소 보내는 중" schedule_id
     else Printf.sprintf "cancelling schedule %s" schedule_id);
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.T.port in
  let run_cancel () =
    let result =
      match admit () with
      | Error refusal -> Error (T.Request_withdrawn refusal)
      | Ok () ->
        (match Masc_tui_http.post_schedule_cancel ~host ~port ~schedule_id with
         | Error detail -> Error (T.Request_failed detail)
         | Ok json ->
           Result.map_error (fun detail -> T.Request_failed detail)
             (Masc.Tui_decode.tool_envelope_outcome json))
    in
    enqueue_async mailbox (P.Schedule_msg (P.Schedule_cancel_done (schedule_id, result)))
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw run_cancel
  | None -> run_cancel ()

let selected_schedule_row (state : T.state) =
  match schedule_detail_on_screen state with
  | Some row -> Some row
  | None ->
      Option.bind state.T.schedules (fun snapshot ->
        List.nth_opt snapshot.T.scs_rows state.T.schedule_cursor)

(* The cancel key on the row under the cursor. Two presses, like the vote
   keys: the first names the schedule, the same press again sends it. The
   schedule id is captured at arm time, so moving the cursor between presses
   re-arms for the new row rather than cancelling the one the operator left. *)
let handle_schedule_cancel_key (state : T.state) ~mailbox =
  match selected_schedule_row state with
  | None -> ()
  | Some row -> (
      match state.T.schedule_cancel_armed with
      | Some armed when String.equal armed row.T.sch_schedule_id ->
          state.T.schedule_cancel_armed <- None;
          start_schedule_cancel state ~mailbox
            ~schedule_id:row.T.sch_schedule_id
      | Some _ | None ->
          state.T.schedule_cancel_armed <- Some row.T.sch_schedule_id;
          state.T.schedule_cancel_error <- None;
          Masc_tui_loader.report_action state "system"
            (T.schedule_cancel_armed_text ~ko:(state.T.ui_language = T.Lang_ko)
               row.T.sch_schedule_id))
