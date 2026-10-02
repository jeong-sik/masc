(** Board detail reads and post/comment/vote execution. *)

open Masc_tui_types
open Masc_tui_async_protocol

module Board_detail = Masc_tui_board_detail

type 'a launch =
  deliver:(('a, string) result -> Masc_tui_async_protocol.async_msg) ->
  (unit -> ('a, string) result) -> unit

let start_board_post_refresh state ~host ~port ~post_id ~launch =
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
  let port = state.port in
  let expected_workspace = state.server_identity in
  launch
    ~deliver:(fun result -> Board_new_post_done { reply_to = None; sent_draft; result })
    (fun () ->
      let ( let* ) = Result.bind in
      let* expected_workspace = match expected_workspace with
        | Some identity -> Ok identity
        | None -> Error "Board workspace identity is unavailable" in
      match Masc_tui_http.post_board_new ~expected_workspace ~host ~port ~title ~body ?hearth () with
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
    ~deliver:(fun result -> Board_new_post_done { reply_to = Some post_id; sent_draft; result })
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
   so the payload says only which post and which way. *)
let start_board_vote state ~host ~launch ~report ~(post_id : string) ~(up : bool) =
  if state.workspace_identity <> Workspace_identity_match then begin
    let detail = "Cannot write to Board: workspace identity is unverified; draft retained" in
    state.board_post_error <- Some detail;
    report "error" detail
  end else begin
  report "system"
    (Printf.sprintf "voting %s on %s" (if up then "up" else "down") post_id);
  let port = state.port in
  let expected_workspace = state.server_identity in
  launch
    ~deliver:(fun result -> Board_vote_done result)
    (fun () ->
      let ( let* ) = Result.bind in
      let* expected_workspace = match expected_workspace with
        | Some identity -> Ok identity
        | None -> Error "Board workspace identity is unavailable" in
      match Masc_tui_http.post_board_vote ~expected_workspace ~host ~port ~post_id ~up with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json )
  end
