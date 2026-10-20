(** Board detail reads and post/comment/vote execution. *)

open Masc_tui_types
open Masc_tui_async_protocol

module Board_detail = Masc_tui_board_detail

type 'a launch =
  deliver:(('a, string) result -> Masc_tui_async_protocol.async_msg) ->
  (unit -> ('a, string) result) -> unit

let start_board_post_refresh state ~host ~port ~post_id ~launch =
  if server_authority_ready state then begin
  if state.board_history_post_id <> Some post_id then
    state.board_history_post_id <- None;
  match Board_detail.start state.board_detail ~post_id with
  | Board_detail.Already_loading -> ()
  | Board_detail.Started (detail, request) ->
    state.board_detail <- detail;
    let full_history = state.board_history_post_id = Some post_id in
    launch
      ~deliver:(fun result -> Board_post_refresh_done (request, result))
      (fun () -> Masc_tui_loader.load_board_post ~full_history ~host ~port ~post_id ())

  end

let start_board_post state ~host ~launch ~report ~(title : string) ~(body : string) ?hearth () =
  if state.workspace_identity <> Workspace_identity_match then begin
    let detail = "Cannot write to Board: workspace identity is unverified; draft retained" in
    state.board_post_error <- Some detail;
    report "error" detail
  end else begin
  state.board_post_error <- None;
  state.board_post_inflight <- true;
  report "system" "posting to Board";
  (* What this send answers for: the completion clears and lands against
     these, not against whatever the operator typed while it was out. *)
  let sent_draft = Buffer.contents state.board_draft in
  let sent_attachments = state.board_compose_attachments in
  let port = state.port in
  let expected_workspace = state.server_identity in
  launch
    ~deliver:(fun result -> Board_new_post_done { reply_to = None; sent_draft; sent_attachments; result })
    (fun () ->
      let ( let* ) = Result.bind in
      let* expected_workspace = match expected_workspace with
        | Some identity -> Ok identity
        | None -> Error "Board workspace identity is unavailable" in
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
          ~upload:(fun ~bytes -> Masc_tui_http.upload_artifact ~host ~port ~bytes)
          sent_attachments
        |> Result.map_error (fun detail -> "not sent, attachment failed: " ^ detail)
      in
      match Masc_tui_http.post_board_new ~expected_workspace ~host ~port ~title ~body ?hearth ~attachments () with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json )
  end


let start_board_comment state ~host ~launch ~report ~(post_id : string)
    ~(content : string) =
  if state.workspace_identity <> Workspace_identity_match then begin
    let detail = "Cannot write to Board: workspace identity is unverified; draft retained" in
    state.board_post_error <- Some detail;
    report "error" detail
  end else begin
  state.board_post_error <- None;
  state.board_post_inflight <- true;
  report "system" "commenting on Board";
  let sent_draft = Buffer.contents state.board_draft in
  let port = state.port in
  let expected_workspace = state.server_identity in
  launch
    ~deliver:(fun result -> Board_new_post_done { reply_to = Some post_id; sent_draft; sent_attachments = []; result })
    (fun () ->
      let ( let* ) = Result.bind in
      let* expected_workspace = match expected_workspace with
        | Some identity -> Ok identity
        | None -> Error "Board workspace identity is unavailable" in
      match Masc_tui_http.post_board_comment ~expected_workspace ~host ~port ~post_id ~content with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json )
  end

(* Send a vote through the tools route. The voter is stamped by the route,
   so the payload says only which target and which way. The completion
   carries the target back, so it can refresh the reading it lands on. *)
let start_vote state ~launch ~report ~target ~(up : bool) ~send =
  if state.workspace_identity <> Workspace_identity_match then begin
    let detail = "Cannot write to Board: workspace identity is unverified; draft retained" in
    state.board_post_error <- Some detail;
    report "error" detail
  end else begin
  report "system"
    (Printf.sprintf "voting %s on %s" (if up then "up" else "down")
       (Masc_tui_board_vote.describe target));
  let port = state.port in
  let expected_workspace = state.server_identity in
  launch
    ~deliver:(fun result -> Board_vote_done (target, result))
    (fun () ->
      let ( let* ) = Result.bind in
      let* expected_workspace = match expected_workspace with
        | Some identity -> Ok identity
        | None -> Error "Board workspace identity is unavailable" in
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
