(** Board detail reads and post/comment/vote execution. *)

open Masc_tui_types
open Masc_tui_async_protocol

module Board_detail = Masc_tui_board_detail

let start_board_post_refresh state ~host ~port ~post_id ~deliver ~report_error =
  (match Board_detail.view_for state.board_detail ~post_id with
   | Board_detail.Absent -> state.board_history_post_id <- None
   | Board_detail.Loading | Board_detail.Ready _ | Board_detail.Failed _ -> ());
  match Board_detail.start state.board_detail ~post_id with
  | Board_detail.Already_loading -> ()
  | Board_detail.Started (detail, request) ->
    state.board_detail <- detail;
    let full_history = state.board_history_post_id = Some post_id in
    let load_result () =
      try Masc_tui_loader.load_board_post ~full_history ~host ~port ~post_id () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    let run_refresh () =
      try
        deliver (Board_post_refresh_done (request, load_result ()))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          deliver
            (Board_post_refresh_done
               (request, Error (Printexc.to_string exn)))
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> Eio.Fiber.fork ~sw run_refresh
    | None -> Masc_tui_board_updates.apply_board_post_load state ~report_error request (load_result ())

(* Post the draft through the tools endpoint. Runs in a fiber like a keeper
   action: the compose pane must keep accepting keys while the request is
   out, and the outcome lands in the same mailbox everything else does. *)
let start_board_post state ~host ~deliver ~report ~(title : string) ~(body : string) ?hearth () =
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
  let run_post () =
    let result =
      match Masc_tui_http.post_board_new ~host ~port ~title ~body ?hearth () with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    deliver
      (Board_new_post_done { reply_to = None; sent_draft; result })
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_post
  | None -> run_post ()
  end

(* Send a comment through the tools route. Same fiber-and-mailbox shape as
   the other board writes; the route stamps the author. *)
let start_board_comment state ~host ~deliver ~report ~(post_id : string)
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
  let run_comment () =
    let result =
      match Masc_tui_http.post_board_comment ~host ~port ~post_id ~content with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    deliver
      (Board_new_post_done { reply_to = Some post_id; sent_draft; result })
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_comment
  | None -> run_comment ()
  end

(* Send a vote through the tools route. The voter is stamped by the route,
   so the payload says only which post and which way. *)

let start_board_vote state ~host ~deliver ~report ~(post_id : string) ~(up : bool) =
  if state.workspace_identity <> Workspace_identity_match then begin
    let detail = "Cannot write to Board: workspace identity is unverified; draft retained" in
    state.board_post_error <- Some detail;
    report "error" detail
  end else begin
  report "system"
    (Printf.sprintf "voting %s on %s" (if up then "up" else "down") post_id);
  let port = state.port in
  let run_vote () =
    let result =
      match Masc_tui_http.post_board_vote ~host ~port ~post_id ~up with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    deliver (Board_vote_done result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_vote
  | None -> run_vote ()
  end
