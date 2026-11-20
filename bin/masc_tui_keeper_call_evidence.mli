(** Pure join of transcript execution identity to an immutable durable call-log
    snapshot. A refresh can keep exact evidence; an incomplete log cannot prove
    absence, and a duplicate execution identity cannot select a receipt. *)
(** Why the call log has no answer: its read's own failure, or the caller's
    kept-back notice for a read the workspace guard did not send. *)
type log_error = Log_failed of string | Log_kept_back of string

type keeper_call_association =
  | Call_log_not_loaded
  | Call_log_loading
  | Call_log_unavailable of string
  | Call_log_kept_back of string
  | Call_execution_unrecorded
  | Call_execution_missing
  | Call_execution_coverage_gap of string
  | Call_execution_ambiguous of int
  | Call_execution_exact of Masc.Tui_decode.keeper_call

val resolve :
  keeper_name:string -> execution_id:string option ->
  loaded_keeper:string option -> loading:bool -> error:log_error option ->
  snapshot:Masc.Tui_decode.keeper_calls_snapshot option -> keeper_call_association

val durable_call_failed : keeper_call_association -> bool
val tool_outcome_label : ?ko:bool -> Masc_tui_keeper_chat_transcript.tool_outcome -> string
val keeper_call_schedule_label : ?ko:bool -> Masc.Tui_decode.keeper_call_schedule -> string

type result_state =
  | Durable_failed
  | Durable_output
  | Transcript_outcome of Masc_tui_keeper_chat_transcript.tool_outcome

val result_state :
  Masc_tui_keeper_chat_transcript.tool_outcome -> keeper_call_association -> result_state
(** Exact durable failure takes priority. A recorded output on an unfinished
    transcript is evidence in the call log, without claiming turn delivery. *)
val result_marker : result_state -> string
val result_label : ?ko:bool -> result_state -> string
