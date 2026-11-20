module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission

(* Everything that names a row stops meaning anything when the surface moves
   to another page or another list: the cursor, the scroll, the open detail
   and a half-armed approve all point at rows this surface is about to stop
   holding. The arm in particular must go -- a second press landing on a row
   that arrived from a different page would approve a task the operator never
   looked at. *)
let reset_verification_rows (state : T.state) =
  state.T.verification_cursor <- 0;
  state.T.verification_scroll <- 0;
  Masc_tui_work_actions.Verification_actions.cancel_verification_evidence_load state
    ~reason:(T.Verification_evidence_read.Interrupted "The original verification detail was closed.");
  state.T.verification_detail_request_id <- None;
  state.T.verification_detail_scroll <- 0;
  state.T.verification_verdict_armed <- None;
  state.T.verification_verdict_error <- None;
  state.T.verification_verdict_inflight <- None

let launch_verification_load (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
  if state.T.verification_inflight then ()
  else begin
    state.T.verification_inflight <- true;
    state.T.verification_owed <- Masc_tui_owed_read.started state.T.verification_owed;
    let host = Admission.server_peer_host in
    let port = state.T.port in
    (* Read once, here, rather than inside the fiber: the operator can press
       another view key while this load is in flight, and the answer that
       arrives must be the one that was asked for. *)
    let view = state.T.verification_view in
    let offset = state.T.verification_offset in
    Admission.launch_guarded_request state ~mailbox ~boundary_error:(fun detail -> T.Request_failed detail)
      ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
      ~deliver:(fun result -> P.Verification_msg (P.Verification_loaded result))
      (fun () -> Masc_tui_loader.load_verification ~host ~port ~limit:200 ~view ~offset
        |> Result.map_error (fun detail -> T.Request_failed detail))
  end
  end
