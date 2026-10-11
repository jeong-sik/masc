module Tui_decode = Masc.Tui_decode
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript

type keeper_call_association =
  | Call_log_not_loaded
  | Call_log_loading
  | Call_log_unavailable of string
  | Call_execution_unrecorded
  | Call_execution_missing
  | Call_execution_coverage_gap of string
  | Call_execution_ambiguous of int
  | Call_execution_exact of Tui_decode.keeper_call

let resolve ~keeper_name ~execution_id ~loaded_keeper ~loading ~error ~snapshot =
  match execution_id with
  | None -> Call_execution_unrecorded
  | Some execution_id -> (
      if
        not
          (Option.equal String.equal loaded_keeper
             (Some keeper_name))
      then Call_log_not_loaded
      (* Refresh keeps the last snapshot for this Keeper. Replacing it with
         a loading row drops every expanded output, changing the transcript's
         height twice per poll and moving the reader's viewport. Only the
         first read has no durable detail to draw yet. *)
      else if loading && Option.is_none snapshot
      then Call_log_loading
      else
      match error, snapshot with
      | Some detail, None -> Call_log_unavailable detail
      | None, None -> Call_log_not_loaded
      | _, Some snapshot
        when not (String.equal snapshot.Tui_decode.kcs_keeper keeper_name) ->
          Call_log_not_loaded
      | _, Some snapshot ->
          let matches =
            List.filter
              (fun (call : Tui_decode.keeper_call) ->
                Option.equal String.equal call.kc_execution_id
                  (Some execution_id))
              snapshot.kcs_entries
          in
          match matches with
          | [] ->
              (match error with
               | Some detail -> Call_log_unavailable detail
               | None when snapshot.Tui_decode.kcs_mismatched > 0 ->
                   (* Filtered foreign rows never join. One of them may carry
                      the queried execution id, so a nonzero mismatch count
                      means this absence is unproven even when health says ok. *)
                   Call_execution_coverage_gap
                     (Printf.sprintf "%d row(s) named another keeper and were not drawn"
                        snapshot.Tui_decode.kcs_mismatched)
               | None -> (
                   (* No match is only proof of absence against a log known
                      complete: [ok], or [empty]/[missing] with nothing in it.
                      Any other verdict -- a coverage gap, a stale read, a word
                      this build does not know -- means the row may exist past
                      what the snapshot covers, so the association says the log
                      is incomplete instead of the row missing. *)
                   match snapshot.Tui_decode.kcs_health with
                   | Tui_decode.Call_log_ok -> Call_execution_missing
                   | (Tui_decode.Call_log_empty | Tui_decode.Call_log_missing)
                     when snapshot.Tui_decode.kcs_entries = [] ->
                       Call_execution_missing
                   | (Tui_decode.Call_log_empty | Tui_decode.Call_log_missing
                     | Tui_decode.Call_log_stale
                     | Tui_decode.Call_log_coverage_gap
                     | Tui_decode.Call_log_unknown _) as health ->
                       let reason =
                         match snapshot.Tui_decode.kcs_stale_reason with
                         | Some reason -> reason
                         | None ->
                             Tui_decode.keeper_call_log_health_to_string health
                       in
                       Call_execution_coverage_gap reason))
          | [ call ] -> Call_execution_exact call
          | rows -> Call_execution_ambiguous (List.length rows))



let durable_call_failed = function
  | Call_execution_exact call ->
      call.kc_outcome = Tool_result.Recorded_failed
      || call.kc_disposition = Some Tui_decode.Keeper_call_failed
  | Call_log_not_loaded | Call_log_loading | Call_log_unavailable _
  | Call_execution_unrecorded | Call_execution_missing
  | Call_execution_coverage_gap _ | Call_execution_ambiguous _ -> false


let tool_outcome_label : Keeper_chat_transcript.tool_outcome -> string = function
  | Keeper_chat_transcript.Started -> "PREPARING · ARGUMENTS STREAMING"
  | Keeper_chat_transcript.Awaiting_result -> "WAITING FOR RESULT"
  | Keeper_chat_transcript.Returned -> "RETURNED"
  | Keeper_chat_transcript.Native_running -> "NATIVE STEP RUNNING"
  | Keeper_chat_transcript.Native_ended -> "NATIVE STEP ENDED · PROVIDER OBSERVATION"
  | Keeper_chat_transcript.Native_failed -> "NATIVE STEP FAILED · PROVIDER OBSERVATION"
  | Keeper_chat_transcript.Failed -> "FAILED"
  | Keeper_chat_transcript.Never_returned -> "RESULT NOT SEEN HERE"
  | Keeper_chat_transcript.Outcome_unrecorded -> "OUTCOME UNRECORDED"


let keeper_call_schedule_label (schedule : Tui_decode.keeper_call_schedule) =
  let execution =
    match schedule.kcs_execution_mode with
    | Tui_decode.Keeper_call_serial -> "serial"
    | Tui_decode.Keeper_call_concurrent -> "concurrent"
  in
  Printf.sprintf "%s · batch %d · width %d · plan step %d" execution
    (schedule.kcs_batch_index + 1) schedule.kcs_batch_size
    (schedule.kcs_planned_index + 1)


type result_state =
  | Durable_failed
  | Durable_output
  | Transcript_outcome of Keeper_chat_transcript.tool_outcome

let result_state outcome association =
  if durable_call_failed association then Durable_failed
  else
    match outcome, association with
    | (Keeper_chat_transcript.Never_returned | Started | Awaiting_result),
      Call_execution_exact call when Option.is_some call.kc_output -> Durable_output
    | (Started | Awaiting_result | Returned | Native_running | Native_ended
      | Native_failed | Failed | Never_returned | Outcome_unrecorded), _ ->
        Transcript_outcome outcome

let result_marker = function
  | Durable_failed -> Keeper_chat_transcript.marker_of_outcome Keeper_chat_transcript.Failed
  | Durable_output -> Keeper_chat_transcript.received_marker
  | Transcript_outcome Keeper_chat_transcript.Returned -> Keeper_chat_transcript.received_marker
  | Transcript_outcome outcome -> Keeper_chat_transcript.marker_of_outcome outcome

let result_label = function
  | Durable_failed -> "failed"
  | Durable_output -> "in call log"
  | Transcript_outcome outcome ->
      match outcome with
      | Keeper_chat_transcript.Started -> "starting"
      | Awaiting_result -> "waiting"
      | Failed -> "failed"
      | Never_returned -> "not seen"
      | Outcome_unrecorded -> "unknown"
      | Native_running -> "native running"
      | Native_ended -> "native ended"
      | Native_failed -> "native failed"
      | Returned -> "received"
