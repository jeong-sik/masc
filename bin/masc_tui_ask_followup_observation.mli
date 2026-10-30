(** Original Ask follow-up observations, independent of the mutable UI loop.
    The read capsule owns provenance; source snapshots do not grant authority. *)
type event =
  | Followup_read_started
  | Followup_worker_entered
  | Followup_source_applied of Masc.Tui_decode_asks.ask_followup_event * int64 * bool
  | Followup_producer_returned of Masc_tui_ask_projection.followup_result
  | Followup_producer_cancelled
  | Followup_job_event of Masc_tui_workspace_job.event
  | Followup_ui_settled of Masc_tui_ask_projection.followup_result

val emit :
  Masc_tui_async_protocol.ask_followup_read ->
  sources:Masc_tui_ask_projection.followup option -> event -> unit
(** Capture the observation clock on entry, before lazy formatting. At the
    existing Transport Info policy, record a readable message and structured
    [details] with [event = "tui_ask_followup"]. Preserve original read identity,
    receipt, producer/job/UI boundaries and typed causes. No question/answer or
    error explanation is logged. Disabled Info still incurs the entry clock,
    but does not build the payload or format the message. *)
