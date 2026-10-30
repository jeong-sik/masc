(** Pure join of transcript execution identity to an immutable durable call-log
    snapshot. A refresh can keep exact evidence; an incomplete log cannot prove
    absence, and a duplicate execution identity cannot select a receipt. *)
type keeper_call_association =
  | Call_log_not_loaded
  | Call_log_loading
  | Call_log_unavailable of string
  | Call_execution_unrecorded
  | Call_execution_missing
  | Call_execution_coverage_gap of string
  | Call_execution_ambiguous of int
  | Call_execution_exact of Masc.Tui_decode.keeper_call

val resolve :
  keeper_name:string -> execution_id:string option ->
  loaded_keeper:string option -> loading:bool -> error:string option ->
  snapshot:Masc.Tui_decode.keeper_calls_snapshot option -> keeper_call_association

val durable_call_failed : keeper_call_association -> bool
val tool_outcome_label : Masc_tui_keeper_chat_transcript.tool_outcome -> string
val keeper_call_schedule_label : Masc.Tui_decode.keeper_call_schedule -> string

type result_state =
  | Durable_failed
  | Durable_output
  | Transcript_outcome of Masc_tui_keeper_chat_transcript.tool_outcome

val result_state :
  Masc_tui_keeper_chat_transcript.tool_outcome -> keeper_call_association -> result_state
(** Exact durable failure takes priority. A recorded output on an unfinished
    transcript is evidence in the call log, without claiming turn delivery. *)
val result_marker : result_state -> string
val result_label : result_state -> string
