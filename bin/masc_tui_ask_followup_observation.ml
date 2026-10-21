open Masc_tui_types
module Ask = Masc_tui_ask_projection

type event =
  | Followup_read_started
  | Followup_worker_entered
  | Followup_source_applied of Masc.Tui_decode_asks.ask_followup_event * int64 * bool
  | Followup_producer_returned of Ask.followup_result
  | Followup_producer_cancelled
  | Followup_job_event of Masc_tui_workspace_job.event
  | Followup_ui_settled of Ask.followup_result

let emit (read : Masc_tui_async_protocol.ask_followup_read) ~sources event =
  match read.afr_submission.as_asker with
  | Masc.Tui_decode_asks.Ask_installation _ -> ()
  | Masc.Tui_decode_asks.Ask_keeper keeper ->
  let observed_ns=Mtime_clock.elapsed_ns () in
  Log.Transport.emit_lazy Log.Info ~keeper_name:keeper
    ~category:Log.Lifecycle (fun () ->
      let request=read.afr_request and submission=read.afr_submission in
      let phase,source,received_ns,source_applied,completion=match event with
        | Followup_read_started -> "started",None,None,None,None
        | Followup_worker_entered -> "worker_entered",None,None,None,None
        | Followup_producer_returned result -> "producer_returned",None,None,None,Some result
        | Followup_producer_cancelled -> "cancelled",None,None,None,Some (Error Ask.Followup_cancelled)
        | Followup_job_event Masc_tui_workspace_job.Cancellation_requested -> "cancel_requested",None,None,None,None
        | Followup_job_event Registration_released -> "registration_released",None,None,None,None
        | Followup_ui_settled result -> "finished",None,None,None,Some result
        | Followup_source_applied (source,received_ns,admitted) ->
          let source=match source with
            | Masc.Tui_decode_asks.Ask_followup_started _ -> "started"
            | Ask_followup_completed _ -> "complete"
            | Ask_followup_source (_,Ask_followup_reactions _) -> "reaction_evidence"
            | Ask_followup_source (_,Ask_followup_tools _) -> "tool_actions"
            | Ask_followup_source (_,Ask_followup_task _) -> "linked_task" in
          "source_processed",Some source,Some received_ns,Some admitted,None in
      let ui_admitted=match event with
        | Followup_source_applied _ | Followup_ui_settled _ -> true
        | Followup_read_started | Followup_worker_entered | Followup_producer_returned _
        | Followup_producer_cancelled | Followup_job_event _ -> false in
      let facts = Option.map Ask.followup_to_json sources in
      let message=Printf.sprintf "Ask follow-up %s: ask=%s request=%d%s"
        phase submission.as_ask_id (Snapshot_read.request_id request)
        (match source with None -> "" | Some source -> " source=" ^ source) in
      message, `Assoc [
        "event", `String "tui_ask_followup";
        "keeper", `String keeper;"ask_id", `String submission.as_ask_id;
        "request", `Int (Snapshot_read.request_id request);
        "origin",Masc_tui_observation_origin.to_json read.afr_origin;
        "read_admission_started_ns",`Intlit (Int64.to_string read.afr_admission_started_ns);
        "submission_started_ns",`Intlit (Int64.to_string submission.as_started_ns);
        "question_source_turn_ref", (match submission.as_source_turn_ref with
          | None -> `Null | Some reference -> Ids.Turn_ref.to_yojson reference);
        "phase", `String phase;"source", (match source with None -> `Null | Some source -> `String source);
        "received_ns", (match received_ns with None -> `Null | Some ns -> `Intlit (Int64.to_string ns));
        "observed_ns",`Intlit (Int64.to_string observed_ns);
        "ui_admitted",(if ui_admitted then `Bool true else `Null);
        "source_applied",(match source_applied with None -> `Null | Some value -> `Bool value);
        "admitted_ns",(if ui_admitted then `Intlit (Int64.to_string observed_ns) else `Null);
        "completion",(match completion with None -> `Null | Some result -> Ask.followup_result_to_json result);
        "sources", (match facts with None -> `Null | Some facts -> facts)])
