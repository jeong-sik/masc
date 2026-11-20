module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Tui_decode = Masc.Tui_decode
module Tui_decode_fusion = Masc.Tui_decode_fusion

let launch_fusion_detail_load ?(demand = Masc_tui_fusion_updates.Share) (state : T.state) ~mailbox ~run_id =
  if T.server_authority_ready state then begin
  let enqueue_async = Masc_tui_transport.Workspace_admission.workspace_enqueue state in
  match Masc_tui_fusion_updates.begin_detail state ~demand ~run_id with
  | None -> ()
  | Some generation ->
    let host = Masc_tui_transport.Workspace_admission.server_peer_host in
    let port = state.T.port in
    let read = Masc_tui_transport.Workspace_admission.capture_json_read state (fun () ->
      Masc_tui_loader.load_fusion_detail ~host ~port ~run_id) in
    Masc_tui_transport.Workspace_admission.launch_guarded_async_read state ~mailbox
      ~deliver:(fun result ->
        enqueue_async mailbox (P.Fusion_msg (P.Fusion_detail_loaded (generation, run_id, result))))
      read
  end

let launch_fusion_historical_detail_load ?(demand = Masc_tui_fusion_updates.Share) (state : T.state) ~mailbox ~reference =
  if T.server_authority_ready state then begin
  let enqueue_async = Masc_tui_transport.Workspace_admission.workspace_enqueue state in
  match Masc_tui_fusion_updates.begin_historical state ~demand ~reference with
  | None -> ()
  | Some generation ->
    let host = Masc_tui_transport.Workspace_admission.server_peer_host in
    let port = state.T.port in
    let read = Masc_tui_transport.Workspace_admission.capture_json_read state (fun () ->
      Masc_tui_loader.load_fusion_historical_detail ~host ~port ~reference) in
    Masc_tui_transport.Workspace_admission.launch_guarded_async_read state ~mailbox
      ~deliver:(fun result ->
        enqueue_async mailbox (P.Fusion_msg (P.Fusion_historical_detail_loaded (generation, reference, result))))
      read
  end

(* Opening a detail is one move -- read the row under the cursor, name it, put
   the pane at the top of it, fetch what the detail needs -- and each surface
   spelled that move inside its own Enter arm, guarded on the detail not being
   open yet.

   [ / ] needs the same move with the opposite guard: the detail IS open and
   the cursor just moved. Spelled twice, the two would drift, and the shape
   that drifts here is "which loads run on open" -- a step that forgot one
   draws the previous row's evidence under the new row's title.

   So the move comes out, ungated, and the two callers bring their own guard.
   The list each reads is the list its own surface draws: Planning filters and
   sorts before indexing, and indexing the unsorted goals would open whichever
   goal happens to sit at that position in the store. *)

let open_planning_detail (state : T.state) ~mailbox =
  let goals =
    match state.T.planning with
    | None -> []
    | Some p ->
        T.planning_visible_goals ~filter:state.T.planning_filter
          ~sort:state.T.planning_sort p.T.pl_goals
  in
  match List.nth_opt goals state.T.planning_cursor with
  | None -> ()
  | Some g ->
      state.T.planning_mode <- T.Planning_detail g.T.pg_id;
      state.T.planning_scroll <- T.Planning_scroll_offset 0;
      state.T.goal_timeline <- Masc_tui_fetched.clear state.T.goal_timeline;
      Masc_tui_work_requests.Tools_task_requests.launch_goal_timeline_load state ~mailbox g.T.pg_id

(* The list row carries one wake; the whole history comes from the exact
   lookup, so opening a detail asks for it. Clearing the previous schedule's
   history first is what stops the pane showing one schedule's attempts under
   another's name while the answer is in flight. *)
let open_schedule_detail (state : T.state) ~mailbox =
  match state.T.schedules with
  | None -> ()
  | Some snapshot ->
      Option.iter
        (fun row ->
          state.T.schedule_detail_id <- Some row.T.sch_schedule_id;
          state.T.schedule_scroll <- 0;
          state.T.schedule_wake_history <- None;
          state.T.schedule_wake_history_error <- None;
          Masc_tui_work_requests.Schedule_call_requests.launch_schedule_wake_history_load state ~mailbox
            ~schedule_id:row.T.sch_schedule_id)
        (List.nth_opt snapshot.T.scs_rows state.T.schedule_cursor)

let open_verification_detail (state : T.state) ~mailbox =
  let requests =
    match state.T.verification with
    | None -> []
    | Some s -> s.Tui_decode.vs_requests
  in
  match List.nth_opt requests state.T.verification_cursor with
  | None -> ()
  | Some row ->
      state.T.verification_detail_request_id <-
        Some row.Tui_decode.vr_request_id;
      state.T.verification_detail_scroll <- 0;
      state.T.verification_evidence_cursor <- 0;
      state.T.verification_evidence_index_open <- false;
      Verification_actions.launch_verification_evidence_load state ~mailbox
        {T.vek_request_id=row.Tui_decode.vr_request_id;vek_task_id=row.Tui_decode.vr_task_id}

let open_harness_detail (state : T.state) =
  match state.T.harness with
  | None -> ()
  | Some snapshot ->
      Option.iter
        (fun verdict ->
          state.T.harness_detail <-
            Some (verdict.Tui_decode.hv_task_id, verdict.Tui_decode.hv_at);
          state.T.harness_detail_scroll <- 0)
        (List.nth_opt snapshot.Tui_decode.hs_verdicts
           state.T.harness_cursor)

let open_fusion_detail (state : T.state) ~mailbox =
  match Masc_tui_fusion_model.selected_fusion_entry state with
  | None -> ()
  | Some (Tui_decode_fusion.Fusion_historical_evidence evidence) ->
      state.T.fusion_mode <- T.Fusion_historical_detail evidence;
      state.T.fusion_scroll <- 0;
      state.T.fusion_historical_detail <- None;
      state.T.fusion_historical_detail_stale <- false;
      state.T.fusion_detail_error <- None;
      launch_fusion_historical_detail_load ~demand:Masc_tui_fusion_updates.After_change
        state ~mailbox ~reference:evidence
  | Some (Tui_decode_fusion.Fusion_retained_run run) ->
      state.T.fusion_mode <- T.Fusion_detail run.Tui_decode_fusion.fur_run_id;
      state.T.fusion_scroll <- 0;
      state.T.fusion_detail <- None;
      state.T.fusion_detail_stale <- false;
      state.T.fusion_detail_error <- None;
      launch_fusion_detail_load ~demand:Masc_tui_fusion_updates.After_change
        state ~mailbox ~run_id:run.Tui_decode_fusion.fur_run_id

let open_selected_system_log (state : T.state) =
  match
    List.nth_opt
      (T.visible_system_log_entries state)
      (T.system_logs_page state).Masc_tui_system_logs.lp_cursor
  with
  | None -> ()
  | Some entry ->
      T.edit_system_logs_page state (fun page ->
        {page with Masc_tui_system_logs.lp_detail_seq=Some entry.Tui_decode.sl_seq;lp_detail_scroll=0})

(* One step through the list a detail was opened from, without closing it.
   Reading a queue meant Esc, move, Enter for every row -- three keys to do
   what one does on Changes and the Keeper detail tabs, both of which already
   spell it [ / ].

   [count] is the surface's own list length, so a step past either end stays
   put rather than wrapping: a reader walking a queue wants to arrive at the
   end and know it, not to reappear at the top. *)
let step_detail_cursor ~count ~cursor ~delta ~set_cursor ~reopen =
  if count > 0 then begin
    let next = max 0 (min (count - 1) (cursor + delta)) in
    if next <> cursor then begin
      set_cursor next;
      reopen ()
    end
  end
