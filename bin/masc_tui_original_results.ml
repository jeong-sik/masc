(* Original Task inspection's async answers: the type [Masc_tui_async_protocol]
   carries in [Original_msg], and how each answer changes the inspection. *)

open Masc_tui_types

type msg =
  | Original_task_read_done of Masc_tui_types.task_inspection_request
      * (Masc_tui_original_task_read.task_snapshot, Masc_tui_original_task_read.error) result
  | Original_task_history_done of Masc_tui_types.task_inspection_request
      * (Masc_tui_original_task_read.history_snapshot, Masc_tui_original_task_read.error) result
  | Original_task_evidence_done of Masc_tui_types.task_inspection_request
      * (Masc_tui_original_task_read.evidence_snapshot, Masc_tui_original_task_read.error) result

type answer_kind = Read

let answer_kind = function
  | Original_task_read_done _ | Original_task_history_done _ | Original_task_evidence_done _ -> Read

let apply state = function
  | Original_task_history_done (request,result) ->
      ignore (complete_original_history_inspection state request result)
  | Original_task_evidence_done (request,result) ->
      ignore (complete_original_evidence_inspection state request result)
  | Original_task_read_done (request,result) ->
      ignore (complete_original_task_inspection state request result)
