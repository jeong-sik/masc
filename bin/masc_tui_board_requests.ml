(** Board detail reads and post/comment/vote execution. *)

open Masc_tui_types
open Masc_tui_async_protocol

module Board_detail = Masc_tui_board_detail
module Publication = Masc_tui_board_publication

type 'a launch =
  deliver:(('a, string) result -> Masc_tui_async_protocol.async_msg) ->
  (unit -> ('a, string) result) -> unit

(* What stays when a write is kept back: a post or a comment keeps its draft,
   a vote has none to keep. *)
type kept = Draft_kept | Nothing_kept

(* A write kept back because the workspace is not confirmed says what
   stopped it, that nothing was sent, and what stayed. *)
let refuse_unconfirmed state ~report kept =
  let ko = state.ui_language = Lang_ko in
  let kept = match kept with
    | Draft_kept -> [ draft_retained ~ko ]
    | Nothing_kept -> [] in
  let detail =
    String.concat " · "
      (String.capitalize_ascii (workspace_identity_unconfirmed ~ko) :: not_sent ~ko :: kept)
  in
  state.board_post_error <- Some detail;
  report "error" detail

let start_board_post_refresh state ~host ~port ~post_id ~launch =
  match state.server_identity with
  | Some expected when server_authority_ready state -> begin
  if state.board_history_post_id <> Some post_id then
    state.board_history_post_id <- None;
  match Board_detail.start state.board_detail ~post_id with
  | Board_detail.Already_loading -> ()
  | Board_detail.Started (detail, request) ->
    state.board_detail <- detail;
    let full_history = state.board_history_post_id = Some post_id in
    launch
      ~deliver:(fun result -> Board_msg (Board_post_refresh_done (request, result)))
      (fun () ->
        Masc_tui_workspace_read.with_binding ~host ~port ~expected
          ~proof:Request_precondition (fun () ->
            Masc_tui_loader.load_board_post ~full_history ~host ~port ~post_id ()))

  end
  | None | Some _ -> ()

type 'authority post_phase =
  | Before_post
  | Calling of 'authority Publication.prepared
  | Observed of 'authority Publication.outcome

let start_board_post state ~host ~results ~admit ~report
    ~(title : string) ~(body : string) ?hearth () =
  if state.workspace_identity <> Workspace_identity_match then
    refuse_unconfirmed state ~report Draft_kept
  else begin
  state.board_post_error <- None;
  let ko = state.ui_language = Lang_ko in
  let request =
    Publication.capture ~authority:state.workspace_authority
      ~host ~port:state.port ~expected_workspace:state.server_identity
      ~sent_draft:(Buffer.contents state.board_draft)
      ~staged:state.board_compose_attachments ~title ~body ~hearth ()
  in
  state.board_publications <- Publication.register state.board_publications request;
  state.board_write <- Board_posting request;
  let phase = ref Before_post in
  let boundary_error detail =
    match !phase with
    | Before_post -> Publication.not_attempted request ~detail
    | Calling prepared ->
      Publication.returned prepared (Publication.unanswered detail)
    | Observed outcome -> outcome
  in
  let started = ref true in
  let settle_not_run () =
    started := false;
    let outcome = boundary_error (if ko then "실행되지 않음" else "did not run") in
    (match Publication.record state.board_publications outcome with
     | Publication.Already_recorded | Publication.Not_registered -> ()
     | Publication.Recorded history -> state.board_publications <- history);
    (match state.board_write with
     | Board_posting current when Publication.same_request current request ->
       state.board_write <- Board_idle;
       state.board_compose_armed <- false;
       state.board_post_error <-
         Some
           (Publication.outcome_unknown ~ko ^ " · "
            ^ if ko then "다시 보내기 전에 게시판을 확인하세요" else "check the Board before retrying")
     | Board_posting _ | Board_idle | Board_commenting _ -> ())
  in
  Masc_tui_workspace_result.launch state ~results ~boundary_error
    ~on_not_run:settle_not_run
    ~cancelled_by:(fun () ->
      Board_msg (Board_publication_done (boundary_error (if ko then "중단됨" else "interrupted"))))
    ~deliver:(function
      | Ok outcome | Error outcome -> Board_msg (Board_publication_done outcome))
    (fun () ->
      let open Result.Syntax in
      let* () = admit request |> Result.map_error boundary_error in
      let* () =
        match request.expected_workspace with
        | Some _ -> Ok ()
        | None -> Error (boundary_error (workspace_identity_unread ~ko))
      in
      (* Staged files upload before the post: a failure here means the post
         was not sent, and the draft and staged list stay as they were. The
         read runs off the UI fiber -- a slow disk or a network mount would
         otherwise hold the screen for as long as it takes. *)
      let* attachments =
        Masc_tui_board_upload.upload_staged
          ~read:(fun path ->
            Eio_guard.run_in_systhread ~label:"tui-board-attachment-read"
              (fun () ->
                Masc_tui_board_upload.read_file
                  ~max_bytes:Masc_tui_board_upload.max_attachment_bytes path))
          ~upload:(fun ~bytes ->
            Masc_tui_http.upload_artifact ~host:request.host ~port:request.port ~bytes)
          request.staged
        |> Result.map_error (fun detail ->
          boundary_error ((if ko then "첨부 실패: " else "attachment failed: ") ^ detail))
      in
      let* prepared =
        Masc_tui_http.prepare_board_new request attachments
        |> Result.map_error boundary_error
      in
      phase := Calling prepared;
      let response = Masc_tui_http.post_board_new prepared in
      let outcome = Publication.returned prepared response in
      phase := Observed outcome;
      Ok outcome);
  if !started then report "system" (if ko then "게시판에 글 올리는 중" else "posting to Board")
  end


let start_board_comment state ~host ~request_id ~launch ~report ~(post_id : string)
    ~(content : string) =
  if state.workspace_identity <> Workspace_identity_match then
    refuse_unconfirmed state ~report Draft_kept
  else begin
  state.board_post_error <- None;
  let ko = state.ui_language = Lang_ko in
  state.board_write <- Board_commenting request_id;
  let sent_draft = Buffer.contents state.board_draft in
  let port = state.port in
  let expected_workspace = state.server_identity in
  launch
    ~deliver:(fun result -> Board_msg (Board_comment_done { request_id; post_id; sent_draft; result }))
    (fun () ->
      let open Result.Syntax in
      let* expected_workspace = match expected_workspace with
        | Some identity -> Ok identity
        | None -> Error (workspace_identity_unread ~ko) in
      match Masc_tui_http.post_board_comment ~expected_workspace ~host ~port ~post_id ~content with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json );
  (match state.board_write with
   | Board_commenting current when current == request_id ->
     report "system" (if ko then "댓글 보내는 중" else "commenting on Board")
   | Board_idle | Board_posting _ | Board_commenting _ -> ())
  end

(* Send a vote through the tools route. The voter is stamped by the route,
   so the payload says only which target and which way. The completion
   carries the target back, so it can refresh the reading it lands on. *)
let start_vote state ~launch ~report ~target ~(up : bool) ~send =
  if state.workspace_identity <> Workspace_identity_match then
    refuse_unconfirmed state ~report Nothing_kept
  else begin
  let ko = state.ui_language = Lang_ko in
  let direction = Masc_tui_board_vote.direction ~ko ~up in
  let target_text = Masc_tui_board_vote.describe ~ko target in
  report "system"
    (if ko then Printf.sprintf "%s %s 보내는 중" target_text direction
     else Printf.sprintf "voting %s on %s" direction target_text);
  let port = state.port in
  let expected_workspace = state.server_identity in
  launch
    ~deliver:(fun result -> Board_msg (Board_vote_done (target, result)))
    (fun () ->
      let open Result.Syntax in
      let* expected_workspace = match expected_workspace with
        | Some identity -> Ok identity
        | None -> Error (workspace_identity_unread ~ko) in
      match send ~expected_workspace ~port with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json )
  end

let start_board_vote state ~host ~launch ~report ~(post_id : string) ~(up : bool) =
  start_vote state ~launch ~report ~target:(Vote_post post_id) ~up
    ~send:(fun ~expected_workspace ~port ->
      Masc_tui_http.post_board_vote ~expected_workspace ~host ~port ~post_id ~up)

let start_board_comment_vote state ~host ~launch ~report ~(post_id : string)
    ~(comment_id : string) ~(up : bool) =
  start_vote state ~launch ~report ~target:(Vote_comment { post_id; comment_id }) ~up
    ~send:(fun ~expected_workspace ~port ->
      Masc_tui_http.post_board_comment_vote ~expected_workspace ~host ~port
        ~comment_id ~up)
