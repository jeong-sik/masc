module Tui_decode = Masc.Tui_decode
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript

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
      let missing = function
        | Log_failed detail -> Call_log_unavailable detail
        | Log_kept_back notice -> Call_log_kept_back notice in
      match error, snapshot with
      | Some error, None -> missing error
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
               | Some error -> missing error
               | None when snapshot.Tui_decode.kcs_mismatched > 0 ->
                   (* Filtered foreign rows never join. One of them may carry
                      the queried execution id, so a nonzero mismatch count
                      means this absence is unproven even when health says ok. *)
                   let mismatched = snapshot.Tui_decode.kcs_mismatched in
                   Call_execution_coverage_gap
                     (if mismatched = 1 then
                        "1 row named another keeper and was not drawn"
                      else
                        Printf.sprintf "%d rows named another keeper and were not drawn"
                          mismatched)
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
  | Call_log_not_loaded | Call_log_loading | Call_log_unavailable _ | Call_log_kept_back _
  | Call_execution_unrecorded | Call_execution_missing
  | Call_execution_coverage_gap _ | Call_execution_ambiguous _ -> false


let tool_outcome_label ?(ko = false) : Keeper_chat_transcript.tool_outcome -> string = function
  | Keeper_chat_transcript.Started ->
      if ko then "준비 중 · 인자 수신 중" else "PREPARING · ARGUMENTS STREAMING"
  | Keeper_chat_transcript.Awaiting_result ->
      if ko then "결과 대기 중" else "WAITING FOR RESULT"
  | Keeper_chat_transcript.Returned ->
      if ko then "반환됨" else "RETURNED"
  | Keeper_chat_transcript.Native_running ->
      if ko then "네이티브 단계 실행 중" else "NATIVE STEP RUNNING"
  | Keeper_chat_transcript.Native_ended ->
      if ko then "네이티브 단계 종료 · 제공자 관측" else "NATIVE STEP ENDED · PROVIDER OBSERVATION"
  | Keeper_chat_transcript.Native_failed ->
      if ko then "네이티브 단계 실패 · 제공자 관측" else "NATIVE STEP FAILED · PROVIDER OBSERVATION"
  | Keeper_chat_transcript.Failed ->
      if ko then "실패" else "FAILED"
  | Keeper_chat_transcript.Never_returned ->
      if ko then "결과 미관측" else "RESULT NOT SEEN HERE"
  | Keeper_chat_transcript.Outcome_unrecorded ->
      if ko then "결과 미기록" else "OUTCOME UNRECORDED"


let keeper_call_schedule_label ?(ko = false) (schedule : Tui_decode.keeper_call_schedule) =
  let execution =
    match schedule.kcs_execution_mode with
    | Tui_decode.Keeper_call_serial -> if ko then "순차" else "serial"
    | Tui_decode.Keeper_call_concurrent -> if ko then "병렬" else "concurrent"
  in
  if ko then
    Printf.sprintf "%s · 배치 %d · 폭 %d · 계획 %d단계" execution
      (schedule.kcs_batch_index + 1) schedule.kcs_batch_size
      (schedule.kcs_planned_index + 1)
  else
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
      | Native_failed | Failed | Never_returned | Outcome_unrecorded),
      ( Call_log_not_loaded | Call_log_loading | Call_log_unavailable _ | Call_log_kept_back _
      | Call_execution_unrecorded | Call_execution_missing
      | Call_execution_coverage_gap _ | Call_execution_ambiguous _
      | Call_execution_exact _ ) ->
        Transcript_outcome outcome

let result_marker = function
  | Durable_failed -> Keeper_chat_transcript.marker_of_outcome Keeper_chat_transcript.Failed
  | Durable_output -> Keeper_chat_transcript.received_marker
  | Transcript_outcome Keeper_chat_transcript.Returned -> Keeper_chat_transcript.received_marker
  | Transcript_outcome
      (( Keeper_chat_transcript.Started | Awaiting_result | Native_running
       | Native_ended | Native_failed | Failed | Never_returned
       | Outcome_unrecorded ) as outcome) ->
      Keeper_chat_transcript.marker_of_outcome outcome

let result_label ?(ko = false) = function
  | Durable_failed -> if ko then "실패" else "failed"
  | Durable_output -> if ko then "호출 기록에 있음" else "in call log"
  | Transcript_outcome outcome ->
      match outcome with
      | Keeper_chat_transcript.Started -> if ko then "시작 중" else "starting"
      | Awaiting_result -> if ko then "대기 중" else "waiting"
      | Failed -> if ko then "실패" else "failed"
      | Never_returned -> if ko then "미관측" else "not seen"
      | Outcome_unrecorded -> if ko then "미기록" else "not recorded"
      | Native_running -> if ko then "네이티브 실행 중" else "native running"
      | Native_ended -> if ko then "네이티브 종료" else "native ended"
      | Native_failed -> if ko then "네이티브 실패" else "native failed"
      | Returned -> if ko then "수신됨" else "received"
