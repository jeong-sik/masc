module T = Masc_tui_types
module Tui_decode = Masc.Tui_decode
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_history = Masc_tui_keeper_chat_history
module Keeper_chat_log = Masc_tui_keeper_chat_log
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript

let apply_keeper_chat_result (state : T.state) (request : Keeper_chat.request) result =
  match T.inflight_by_request_id state request.Keeper_chat.request_id with
  | Some current when Keeper_chat.same_request_identity current request ->
      (match result with
       | Error error
         when Keeper_chat.error_certainty ~was_unverified:false error
              = Keeper_chat.Outcome_unverified ->
           let detail =
             Keeper_chat.reconciliation_failure_detail
               ~credential_sent:(Masc_tui_http.operator_token_present ())
               error
             |> Keeper_chat.terminal_safe_text
           in
           Masc_tui_chat_dispatch.Chat_watching.append_chat_history state request T.Message_status
             (Printf.sprintf
                "Outcome still unverified for %s; holding NEXT while the exact operation is reconciled. %s"
                request.Keeper_chat.request_id detail);
           Masc_tui_loader.report_action state "error"
             (Printf.sprintf "Keeper request still unverified: %s"
                request.Keeper_chat.request_id);
           false
       | (Ok _ | Error _) as result ->
         (match result with
          | Error error when Keeper_chat.error_certainty ~was_unverified:false error = Keeper_chat.Verified_rejected ->
              (match T.inflight_entry_by_request_id state request.Keeper_chat.request_id with
               | Some entry ->
                   Keeper_chat_transcript.note_rejection ~now:(Unix.gettimeofday ())
                     entry.T.log.T.tl_transcript (Keeper_chat.error_to_string error);
                   Keeper_chat_log.commit entry.T.log.T.tl_log;
                   T.hold_settled_log state entry.T.log
               | None -> ())
          | Ok _ | Error _ -> ());
         T.drop_inflight state request;
         (match result with
       | Ok (Keeper_chat.Turn_completed completed) ->
           (* A turn the settled log holds is drawn from it, reply included
              ([Keeper_chat_transcript.drawn] reconciles the recorded reply by
              outcome). The row here is for a turn whose stream never told the
              pane how it ended, so the strict decode is the one source. *)
           (match T.completed_turn_row state request completed with
            | Some (role, text) ->
                Masc_tui_chat_dispatch.Chat_watching.append_chat_history ~turn_phase:T.Turn_output state request role
                  text
            | None -> ());
           Masc_tui_loader.add_event state "message"
             (Printf.sprintf "Keeper turn finished: %s" request.Keeper_chat.request_id)
       | Ok (Keeper_chat.Replayed_succeeded _) ->
           (* The server answered [Existing] for this id: the turn already ran
              and this POST produced no second one. When the log holds the
              turn -- a cut after the reply, a re-POST that replayed nothing
              new -- the reply is on screen and this row would say it is not. *)
           if
             not
               (Option.exists T.turn_log_holds_the_turn
                  (T.settled_log_for_request state
                     ~keeper_name:request.Keeper_chat.keeper_name
                     request.Keeper_chat.request_id))
           then
             Masc_tui_chat_dispatch.Chat_watching.append_chat_history ~turn_phase:T.Turn_output state request
               T.Message_status
               "Request was already completed; canonical reply is not present in this replay stream";
           Masc_tui_loader.add_event state "message"
             (Printf.sprintf "Keeper request already completed: %s"
                request.Keeper_chat.request_id)
       | Error error ->
           (* A 401 here is a credential problem, and which one depends on
              whether this process presented a bearer at all. Every other
              failure keeps the server's own words. *)
           let detail =
             Keeper_chat.reconciliation_failure_detail
               ~credential_sent:(Masc_tui_http.operator_token_present ())
               error
             |> Keeper_chat.terminal_safe_text
           in
           let detail =
             match Keeper_chat.error_certainty ~was_unverified:false error with
             | Keeper_chat.Verified_rejected | Keeper_chat.Verified_failed ->
                 detail
             | Keeper_chat.Outcome_unverified -> assert false
           in
           let detail =
             match Keeper_chat_history.present_delivery_failure detail with
             | Some (presented, _) -> presented
             | None -> detail
           in
           Masc_tui_chat_dispatch.Chat_watching.append_chat_history ~turn_phase:T.Turn_output state request
             T.Message_error detail;
           Masc_tui_loader.report_action state "error"
             (Printf.sprintf "Keeper message %s: %s" request.Keeper_chat.request_id detail));
         true)
  | Some _ | None -> false

(* Revoke the whole workspace-owned detail population before any successor
   starts. Queued plain replies carry the old authority token; fetched reads
   and Sandbox logs have their own monotonic request generations. *)
let revoke_detail_readings (state : T.state) =
  Masc_tui_work_requests.Schedule_call_requests.close_chat_call_reader state;
  T.close_detail_reading state;
  state.T.detail_reads <- [];
  state.T.detail_read_authority <- ref ();
  state.T.keeper_sandbox_view <- None;
  state.T.keeper_board_quarantines <- Masc_tui_fetched.clear state.T.keeper_board_quarantines;
  state.T.keeper_efficiency <- Masc_tui_fetched.clear state.T.keeper_efficiency;
  state.T.keeper_sandbox_logs_generation <- state.T.keeper_sandbox_logs_generation + 1;
  state.T.keeper_sandbox_logs_inflight <- None;
  state.T.keeper_sandbox_logs <- None;
  state.T.keeper_sandbox_logs_error <- None;
  state.T.keeper_composite_inflight <- None;
  state.T.keeper_composite_owed <- None;
  state.T.keeper_composite <- None;
  state.T.keeper_composite_error <- None;
  T.clear_connectors_read state;
  state.T.connectors <- None;
  state.T.connectors_error <- None;
  state.T.connector_unbind_offer <- None;
  state.T.connector_unbind_armed <- None;
  state.T.connector_unbind_all_armed <- None;
  state.T.volume_gc <- Masc_tui_volume_gc.initial;
  T.withdraw_identity_readings state;
  state.T.keeper_schedules <- None;
  state.T.keeper_schedules_error <- None;
  state.T.keeper_schedules_page <- None;
  state.T.keeper_schedules_pending <- None;
  state.T.fusion_runs <- Masc_tui_fetched.clear state.T.fusion_runs;
  state.T.fusion_runs_reread_pending <- false;
  state.T.fusion_runs_awaiting_observer <- false;
  state.T.fusion_runs_open_at_start <- None

let same_currency_workspace source current =
  match source, current with
  | Some source, Some current
    when source.Tui_decode.sid_state_ready <> Some false
      && current.Tui_decode.sid_state_ready <> Some false ->
      Tui_decode.Canonical_path.equal source.Tui_decode.sid_base_path current.Tui_decode.sid_base_path
      && Tui_decode.Canonical_path.equal source.Tui_decode.sid_masc_root current.Tui_decode.sid_masc_root
  | _ -> false

let withdraw_currency_authority (state : T.state) =
  state.T.candle_authority_generation <- state.T.candle_authority_generation + 1;
  state.T.candle_observation <- None
