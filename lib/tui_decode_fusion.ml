open Tui_decode_fields

let ( let* ) = Result.bind

type fusion_run_status =
  | Fusion_running
  | Fusion_completed
  | Fusion_failed of {
      frs_failure_code : string;
      frs_error : string;
    }

type fusion_run_stage =
  | Fusion_stage_accepted
  | Fusion_stage_panel of { frs_expected : int }
  | Fusion_stage_judge of
      { frs_expected : int
      ; frs_answered : int
      ; frs_failed : int
      }
  | Fusion_stage_computed of
      { frs_expected : int
      ; frs_answered : int
      ; frs_failed : int
      }
  | Fusion_stage_recording_evidence of
      { frs_expected : int
      ; frs_answered : int
      ; frs_failed : int
      }
  | Fusion_stage_completed
  | Fusion_stage_failed

type fusion_run = {
  fur_run_id : string;
  fur_keeper : string;
  fur_preset : string;
  fur_topology : Fusion_types.fusion_topology;
  fur_started_at : float;
  fur_finished_at : float option;
  fur_status : fusion_run_status;
  fur_stage : fusion_run_stage;
  fur_decision : string option;
  fur_summary : string option;
}

type fusion_replay =
  | Fusion_not_replayed
  | Fusion_log_absent
  | Fusion_replayed of
      { malformed_lines : int; dropped_running : int; incomplete : bool }

type fusion_historical_evidence = {
  fhe_run_id : string;
  fhe_post_id : string;
  fhe_title : string;
  fhe_created_at : float;
}

type fusion_list_entry =
  | Fusion_retained_run of fusion_run
  | Fusion_historical_evidence of fusion_historical_evidence

type fusion_snapshot = {
  fus_generated_at : string;
  fus_runs : fusion_run list;
  fus_replay : fusion_replay;
  fus_historical_evidence : fusion_historical_evidence list;
}

type fusion_panel_answer = {
  fpa_model : string;
  fpa_answer : string;
  fpa_input_tokens : int;
  fpa_output_tokens : int;
}

type fusion_panel_failure = {
  fpf_model : string;
  fpf_reason_code : string;
  fpf_reason_detail : string;
}

type fusion_panel_result =
  | Fusion_panel_answered of fusion_panel_answer
  | Fusion_panel_failed of fusion_panel_failure

type fusion_judge =
  | Fusion_judge_synthesized of {
      fj_decision : string;
      fj_resolved_answer : string;
      fj_reason : string;
    }
  | Fusion_judge_failed of {
      fj_failure_code : string;
      fj_error : string;
    }

(* RFC-0284 judge-node roles: the kind the server's judge_role_projection
   writes, read back through the same closed set it wrote from, so a role
   this build was not taught fails the node instead of drawing it as
   something it is not. [Judge_stage_meta] carries no number on purpose --
   the identity string ("stage-1") is what the server projects and what a
   row prints. *)
type fusion_judge_role = Fusion_types.judge_role_kind =
  | Judge_single
  | Judge_refine
  | Judge_first
  | Judge_meta
  | Judge_stage_meta
  | Judge_final_meta

type fusion_judge_node_outcome =
  | Judge_node_synthesized of {
      fjno_decision : string;
      fjno_resolved_answer : string;
      fjno_synthesis : string;
      fjno_input_tokens : int;
      fjno_output_tokens : int;
    }
  | Judge_node_failed of {
      fjno_failure_code : string;
      fjno_error : string;
      fjno_input_tokens : int;
      fjno_output_tokens : int;
      fjno_elapsed_s : float option;
      fjno_timed_out : bool;
    }

(* One executed judge of the deliberation, panel-shaped: the role says where
   the node sits in the topology, the identity names the lens (a first-pass
   judge) or the stage, and the outcome is the synthesis or the failure. *)
type fusion_judge_node = {
  fjn_role : fusion_judge_role;
  fjn_identity : string;
  fjn_outcome : fusion_judge_node_outcome;
}

type fusion_tool_phase =
  | Fusion_tool_panel
  | Fusion_tool_judge of fusion_judge_role

type fusion_tool_actor =
  { fta_phase : fusion_tool_phase
  ; fta_identity : string
  }

type fusion_tool_preview =
  { ftp_text : string
  ; ftp_bytes : int
  ; ftp_truncated : bool
  }

type fusion_tool_completion =
  | Fusion_tool_succeeded of fusion_tool_preview
  | Fusion_tool_failed of
      { ftc_output : fusion_tool_preview
      ; ftc_recoverable : bool
      ; ftc_error_class : string option
      }

type fusion_tool_event =
  | Fusion_tool_called of
      { fte_actor : fusion_tool_actor
      ; fte_agent_name : string
      ; fte_tool_use_id : string
      ; fte_turn : int
      ; fte_planned_index : int
      ; fte_tool_name : string
      ; fte_input : fusion_tool_preview
      }
  | Fusion_tool_completed of
      { fte_actor : fusion_tool_actor
      ; fte_agent_name : string
      ; fte_tool_use_id : string
      ; fte_turn : int
      ; fte_planned_index : int
      ; fte_tool_name : string
      ; fte_completion : fusion_tool_completion
      }

type fusion_tool_gap =
  { ftg_actor : fusion_tool_actor
  ; ftg_reason : string
  }

type fusion_tool_trace =
  { ftt_complete : bool
  ; ftt_observed_actors : fusion_tool_actor list
  ; ftt_dropped_events : int
  ; ftt_gaps : fusion_tool_gap list
  ; ftt_events : fusion_tool_event list
  }

(* One seat's route through its candidates (the sink's [seat_routes] array):
   who was tried, who answered. A panel seat is its panelist id; a judge seat
   is its topology role and identity, read back through the same closed role
   set the tool actors use. *)
type fusion_seat =
  | Fusion_panel_seat of string
  | Fusion_judge_seat of { fs_role : fusion_judge_role; fs_identity : string }

type fusion_seat_attempt =
  { fsa_runtime : string
  ; fsa_code : string
  ; fsa_detail : string
  }

type fusion_seat_route =
  { fsr_seat : fusion_seat
  ; fsr_route : string
  ; fsr_answered_by : string option
        (** [None]: every candidate failed, or the route did not resolve. *)
  ; fsr_failed_attempts : fusion_seat_attempt list
  }

type fusion_evidence = {
  fe_post_id : string;
  fe_title : string;
  fe_question : string;
  fe_panel : fusion_panel_result list;
  fe_judge : fusion_judge;
  fe_judges : fusion_judge_node list;
  fe_tool_trace : fusion_tool_trace;
  fe_seat_routes : fusion_seat_route list option;
      (** [None] when the post's meta carries no [seat_routes] key, which is
          how a post written before seats were recorded reads; the detail
          draws no block for it. An empty list is a post that carries the key
          with no seat in it. *)
}

type fusion_evidence_status =
  | Fusion_evidence_recorded
  | Fusion_evidence_pending
  | Fusion_evidence_absent

type fusion_detail = {
  fud_generated_at : string;
  fud_run : fusion_run;
  fud_evidence_status : fusion_evidence_status;
  fud_evidence : fusion_evidence option;
}

type fusion_historical_detail = {
  fhd_reference : fusion_historical_evidence;
  fhd_author : string;
  fhd_title : string;
  fhd_body : string;
  fhd_observations : ((int * int) option * float option, string) result;
  fhd_evidence : (fusion_evidence, string) result;
}

let fusion_run_status_to_string = function
  | Fusion_running -> "running"
  | Fusion_completed -> "completed"
  | Fusion_failed _ -> "failed"

let fusion_run_stage_to_string = function
  | Fusion_stage_accepted -> "accepted"
  | Fusion_stage_panel _ -> "panel"
  | Fusion_stage_judge _ -> "judge"
  | Fusion_stage_computed _ -> "computed"
  | Fusion_stage_recording_evidence _ -> "recording evidence"
  | Fusion_stage_completed -> "completed"
  | Fusion_stage_failed -> "failed"

let decode_fusion_progress_counts progress =
  let* frs_expected = required_int_field progress "panel_expected" in
  let* frs_answered = required_int_field progress "panel_answered" in
  let* frs_failed = required_int_field progress "panel_failed" in
  if frs_expected < 0 || frs_answered < 0 || frs_failed < 0 then
    Error "fusion progress counts must be non-negative"
  else if frs_answered + frs_failed <> frs_expected then
    Error "fusion answered + failed counts must equal panel_expected"
  else Ok (frs_expected, frs_answered, frs_failed)

let decode_fusion_stage ~status ~stage ~progress =
  match status, stage, progress with
  | Fusion_running, "accepted", `Assoc _ -> Ok Fusion_stage_accepted
  | Fusion_running, "panel", (`Assoc _ as progress) ->
      let* frs_expected = required_int_field progress "panel_expected" in
      if frs_expected < 0 then
        Error "fusion panel_expected must be non-negative"
      else Ok (Fusion_stage_panel { frs_expected })
  | Fusion_running, "judge", (`Assoc _ as progress) ->
      let* frs_expected, frs_answered, frs_failed =
        decode_fusion_progress_counts progress
      in
      Ok (Fusion_stage_judge { frs_expected; frs_answered; frs_failed })
  | Fusion_running, "computed", (`Assoc _ as progress) ->
      let* frs_expected, frs_answered, frs_failed =
        decode_fusion_progress_counts progress
      in
      Ok (Fusion_stage_computed { frs_expected; frs_answered; frs_failed })
  | Fusion_running, "recording_evidence", (`Assoc _ as progress) ->
      let* frs_expected, frs_answered, frs_failed =
        decode_fusion_progress_counts progress
      in
      Ok
        (Fusion_stage_recording_evidence
           { frs_expected; frs_answered; frs_failed })
  | Fusion_completed, "completed", `Null -> Ok Fusion_stage_completed
  | Fusion_failed _, "failed", `Null -> Ok Fusion_stage_failed
  | _ ->
      Error
        (Printf.sprintf "fusion status/stage/progress disagree: status=%s stage=%S"
           (fusion_run_status_to_string status) stage)

let decode_fusion_run json =
  let* fur_run_id = required_string_field json "run_id" in
  let* fur_keeper = required_string_field json "keeper" in
  let* fur_preset = required_string_field json "preset" in
  let* topology = required_string_field json "topology" in
  let* fur_topology =
    match Fusion_types.fusion_topology_of_string topology with
    | Some topology -> Ok topology
    | None -> Error (Printf.sprintf "unknown fusion topology %S" topology)
  in
  let* fur_started_at = Json_util.require_float json "started_at" in
  let* fur_finished_at = required_nullable_float_field json "finished_at" in
  let* status = required_string_field json "status" in
  let* fur_status =
    match status with
    | "running" -> Ok Fusion_running
    | "completed" -> Ok Fusion_completed
    | "failed" ->
        let* frs_failure_code = required_string_field json "failure_code" in
        let* frs_error = required_string_field json "error" in
        Ok (Fusion_failed { frs_failure_code; frs_error })
    | other -> Error (Printf.sprintf "unknown fusion run status %S" other)
  in
  let* () =
    match fur_status, fur_finished_at with
    | Fusion_running, None -> Ok ()
    | (Fusion_completed | Fusion_failed _), Some ts when Float.is_finite ts && ts >= 0. -> Ok ()
    | _ -> Error "Fusion finish timestamp disagrees with run status"
  in
  let* stage = required_string_field json "stage" in
  let* progress = required_member json "progress" in
  let* fur_stage = decode_fusion_stage ~status:fur_status ~stage ~progress in
  let* fur_decision = optional_string_field json "decision" in
  let* fur_summary = optional_string_field json "summary" in
  let* () =
    match fur_status, fur_decision, fur_summary with
    | Fusion_completed, None, None
    | Fusion_completed, Some _, Some _
    | Fusion_running, None, None
    | Fusion_failed _, None, None -> Ok ()
    | Fusion_completed, (Some _ | None), (Some _ | None) ->
        Error "fusion completion decision and summary must appear together"
    | (Fusion_running | Fusion_failed _), (Some _ | None), (Some _ | None) ->
        Error "only a completed Fusion run may carry decision and summary"
  in
  Ok
    { fur_run_id
    ; fur_keeper
    ; fur_preset
    ; fur_topology
    ; fur_started_at
    ; fur_finished_at
    ; fur_status
    ; fur_stage
    ; fur_decision
    ; fur_summary
    }

let decode_fusion_replay json =
  let* status = required_string_field json "status" in
  match status with
  | "not_replayed" -> Ok Fusion_not_replayed
  | "absent" -> Ok Fusion_log_absent
  | "complete" | "incomplete" ->
      let* _lines_read = required_nonnegative_int_field json "lines_read" in
      let* malformed_lines = required_nonnegative_int_field json "malformed_lines" in
      let* dropped_running = required_nonnegative_int_field json "dropped_running" in
      Ok (Fusion_replayed { malformed_lines; dropped_running;
                            incomplete = String.equal status "incomplete" })
  | other -> Error (Printf.sprintf "unknown Fusion replay status %S" other)

let decode_fusion_historical_evidence json =
  let* fhe_run_id = required_string_field json "run_id" in
  let* fhe_post_id = required_string_field json "post_id" in
  let* fhe_title = required_string_field json "title" in
  let* fhe_created_at = Json_util.require_float json "created_at" in
  if String.trim fhe_run_id = "" || String.trim fhe_post_id = "" then
    Error "historical Fusion evidence requires a run and Board post identity"
  else if not (Float.is_finite fhe_created_at) || fhe_created_at < 0. then
    Error "historical Fusion evidence publication time must be finite and nonnegative"
  else Ok { fhe_run_id; fhe_post_id; fhe_title; fhe_created_at }

let decode_fusion_snapshot json =
  let* fus_generated_at = required_string_field json "generated_at" in
  let* count = required_int_field json "count" in
  let* runs_json = required_list_field json "runs" in
  let* fus_runs = decode_list "runs" decode_fusion_run runs_json in
  if count <> List.length fus_runs then
    Error
      (Printf.sprintf "fusion run count is %d but runs contains %d rows" count
         (List.length fus_runs))
  else
    let* replay = required_member json "replay" in
    let* fus_replay = decode_fusion_replay replay in
    let* history = required_list_field json "historical_evidence" in
    let* fus_historical_evidence =
      decode_list "historical_evidence" decode_fusion_historical_evidence history
    in
    Ok { fus_generated_at; fus_runs; fus_replay; fus_historical_evidence }

let decode_fusion_panel_result json =
  let* model = required_string_field json "model" in
  let* status = required_string_field json "status" in
  match status with
  | "answered" ->
      let* fpa_answer = required_string_field json "answer" in
      let* fpa_input_tokens = required_int_field json "input_tokens" in
      let* fpa_output_tokens = required_int_field json "output_tokens" in
      Ok
        (Fusion_panel_answered
           { fpa_model = model
           ; fpa_answer
           ; fpa_input_tokens
           ; fpa_output_tokens
           })
  | "failed" ->
      let* fpf_reason_code = required_string_field json "reason_code" in
      let* fpf_reason_detail = required_string_field json "reason_detail" in
      Ok
        (Fusion_panel_failed
           { fpf_model = model; fpf_reason_code; fpf_reason_detail })
  | other -> Error (Printf.sprintf "unknown fusion panel status %S" other)

let decode_fusion_judge json =
  let* status = required_string_field json "status" in
  match status with
  | "synthesized" ->
      let* fj_decision = required_string_field json "decision" in
      let* fj_resolved_answer = required_string_field json "resolved_answer" in
      let* fj_reason = required_string_field json "synthesis" in
      Ok
        (Fusion_judge_synthesized
           { fj_decision; fj_resolved_answer; fj_reason })
  | "failed" ->
      let* fj_failure_code = required_string_field json "failure_code" in
      let* fj_error = required_string_field json "error" in
      Ok (Fusion_judge_failed { fj_failure_code; fj_error })
  | other -> Error (Printf.sprintf "unknown fusion judge status %S" other)

(* The labels live beside the producer in [Fusion_types]; judge nodes read
   one off ["role"], tool-trace actors off ["judge_role"]. *)
let fusion_judge_role_of_label = Fusion_types.judge_role_kind_of_label
let fusion_judge_role_label = Fusion_types.judge_role_kind_label

let decode_fusion_judge_role json =
  let* role = required_string_field json "role" in
  fusion_judge_role_of_label role

let decode_fusion_judge_node json =
  let* fjn_role = decode_fusion_judge_role json in
  let* fjn_identity = required_string_field json "identity" in
  let* status = required_string_field json "status" in
  let* fjn_outcome =
    match status with
    | "synthesized" ->
        let* fjno_decision = required_string_field json "decision" in
        let* fjno_resolved_answer =
          required_string_field json "resolved_answer"
        in
        let* fjno_synthesis = required_string_field json "synthesis" in
        let* fjno_input_tokens = required_int_field json "input_tokens" in
        let* fjno_output_tokens = required_int_field json "output_tokens" in
        Ok
          (Judge_node_synthesized
             { fjno_decision
             ; fjno_resolved_answer
             ; fjno_synthesis
             ; fjno_input_tokens
             ; fjno_output_tokens
             })
    | "failed" ->
        let* fjno_failure_code = required_string_field json "failure_code" in
        let* fjno_error = required_string_field json "error" in
        let* fjno_input_tokens = required_int_field json "input_tokens" in
        let* fjno_output_tokens = required_int_field json "output_tokens" in
        (* [elapsed_s] is `Null` when the failure left no clock reading, and
           [timed_out] is derived server-side from the failure itself. *)
        let* fjno_elapsed_s = optional_float_field json "elapsed_s" in
        let* fjno_timed_out = required_bool_field json "timed_out" in
        Ok
          (Judge_node_failed
             { fjno_failure_code
             ; fjno_error
             ; fjno_input_tokens
             ; fjno_output_tokens
             ; fjno_elapsed_s
             ; fjno_timed_out
             })
    | other -> Error (Printf.sprintf "unknown fusion judge node status %S" other)
  in
  Ok { fjn_role; fjn_identity; fjn_outcome }

let decode_fusion_tool_actor json =
  let* phase = required_string_field json "phase" in
  let* fta_identity = required_string_field json "actor" in
  let* judge_role = optional_string_field json "judge_role" in
  match phase, judge_role with
  | "panel", None -> Ok { fta_phase = Fusion_tool_panel; fta_identity }
  | "judge", Some role ->
      let* role = fusion_judge_role_of_label role in
      Ok { fta_phase = Fusion_tool_judge role; fta_identity }
  | "panel", Some _ -> Error "fusion panel tool actor cannot carry judge_role"
  | "judge", None -> Error "fusion judge tool actor requires judge_role"
  | phase, _ -> Error (Printf.sprintf "unknown fusion tool phase %S" phase)

let decode_fusion_tool_preview json =
  let* ftp_text = required_string_field json "text" in
  let* ftp_bytes = required_int_field json "bytes" in
  let* ftp_truncated = required_bool_field json "truncated" in
  let shown_bytes = String.length ftp_text in
  if ftp_bytes < 0 then Error "fusion tool preview bytes must be non-negative"
  else if (not ftp_truncated) && ftp_bytes <> shown_bytes then
    Error "fusion complete tool preview byte count disagrees with text"
  else if ftp_truncated && ftp_bytes <= shown_bytes then
    Error "fusion truncated tool preview must report a larger source byte count"
  else Ok { ftp_text; ftp_bytes; ftp_truncated }

let decode_fusion_tool_common json =
  let* fte_actor = decode_fusion_tool_actor json in
  let* fte_agent_name = required_string_field json "agent_name" in
  let* fte_tool_use_id = required_string_field json "tool_use_id" in
  let* fte_turn = required_int_field json "turn" in
  let* fte_planned_index = required_int_field json "planned_index" in
  let* fte_tool_name = required_string_field json "tool_name" in
  if fte_turn < 0 || fte_planned_index < 0 then
    Error "fusion tool turn and planned_index must be non-negative"
  else
    Ok
      ( fte_actor
      , fte_agent_name
      , fte_tool_use_id
      , fte_turn
      , fte_planned_index
      , fte_tool_name )

let decode_fusion_tool_event json =
  let* event = required_string_field json "event" in
  let* ( fte_actor
       , fte_agent_name
       , fte_tool_use_id
       , fte_turn
       , fte_planned_index
       , fte_tool_name ) =
    decode_fusion_tool_common json
  in
  match event with
  | "called" ->
      let* input = required_object_field json "input" in
      let* fte_input = decode_fusion_tool_preview input in
      Ok
        (Fusion_tool_called
           { fte_actor
           ; fte_agent_name
           ; fte_tool_use_id
           ; fte_turn
           ; fte_planned_index
           ; fte_tool_name
           ; fte_input
           })
  | "completed" ->
      let* status = required_string_field json "status" in
      let* output = required_object_field json "output" in
      let* output = decode_fusion_tool_preview output in
      let* recoverable = optional_bool_field json "recoverable" in
      let* error_class = optional_string_field json "error_class" in
      let* fte_completion =
        match status, recoverable, error_class with
        | "succeeded", None, None -> Ok (Fusion_tool_succeeded output)
        | "failed", Some ftc_recoverable, ftc_error_class
          when Option.for_all
                 (fun class_ ->
                    List.mem class_ [ "transient"; "deterministic"; "unknown" ])
                 ftc_error_class ->
          Ok
            (Fusion_tool_failed
               { ftc_output = output; ftc_recoverable; ftc_error_class })
        | "succeeded", (Some _ | None), (Some _ | None) ->
          Error "successful fusion tool completion cannot carry failure fields"
        | "failed", None, _ ->
          Error "failed fusion tool completion requires recoverable"
        | "failed", Some _, Some class_ ->
          Error (Printf.sprintf "unknown fusion tool error_class %S" class_)
        | status, _, _ ->
          Error (Printf.sprintf "unknown fusion tool completion status %S" status)
      in
      Ok
        (Fusion_tool_completed
           { fte_actor
           ; fte_agent_name
           ; fte_tool_use_id
           ; fte_turn
           ; fte_planned_index
           ; fte_tool_name
           ; fte_completion
           })
  | event -> Error (Printf.sprintf "unknown fusion tool event %S" event)

let decode_fusion_tool_gap json =
  let* ftg_actor = decode_fusion_tool_actor json in
  let* ftg_reason = required_string_field json "reason" in
  if String.equal ftg_reason "official_client_uninstrumented"
  then Ok { ftg_actor; ftg_reason }
  else Error (Printf.sprintf "unknown fusion tool trace gap %S" ftg_reason)

let decode_fusion_tool_trace json =
  let* status = required_string_field json "status" in
  let* actor_json = required_list_field json "observed_actors" in
  let* ftt_observed_actors =
    decode_list "observed_actors" decode_fusion_tool_actor actor_json
  in
  let* ftt_dropped_events = required_int_field json "dropped_events" in
  let* gap_json = required_list_field json "gaps" in
  let* ftt_gaps = decode_list "gaps" decode_fusion_tool_gap gap_json in
  let* event_json = required_list_field json "events" in
  let* ftt_events = decode_list "events" decode_fusion_tool_event event_json in
  if ftt_dropped_events < 0 then
    Error "fusion tool dropped_events must be non-negative"
  else
    let expected_status =
      if ftt_dropped_events = 0 && ftt_gaps = [] then "complete" else "partial"
    in
    if not (String.equal status expected_status) then
      Error
        (Printf.sprintf
           "fusion tool trace status %S disagrees with drops/gaps; expected %S"
           status expected_status)
    else
      Ok
        { ftt_complete = String.equal status "complete"
        ; ftt_observed_actors
        ; ftt_dropped_events
        ; ftt_gaps
        ; ftt_events
        }

let decode_fusion_seat json =
  let* phase = required_string_field json "phase" in
  let* fs_identity = required_string_field json "seat" in
  let* judge_role = optional_string_field json "judge_role" in
  match phase, judge_role with
  | "panel", None -> Ok (Fusion_panel_seat fs_identity)
  | "judge", Some role ->
      let* fs_role = fusion_judge_role_of_label role in
      Ok (Fusion_judge_seat { fs_role; fs_identity })
  | "panel", Some _ -> Error "fusion panel seat cannot carry judge_role"
  | "judge", None -> Error "fusion judge seat requires judge_role"
  | phase, _ -> Error (Printf.sprintf "unknown fusion seat phase %S" phase)

let decode_fusion_seat_attempt json =
  let* fsa_runtime = required_string_field json "runtime" in
  let* fsa_code = required_string_field json "code" in
  let* fsa_detail = required_string_field json "detail" in
  Ok { fsa_runtime; fsa_code; fsa_detail }

let decode_fusion_seat_route json =
  let* fsr_seat = decode_fusion_seat json in
  let* fsr_route = required_string_field json "route" in
  let* fsr_answered_by = required_nullable_string_field json "answered_by" in
  let* attempts = required_list_field json "failed_attempts" in
  let* fsr_failed_attempts =
    decode_list "failed_attempts" decode_fusion_seat_attempt attempts
  in
  Ok { fsr_seat; fsr_route; fsr_answered_by; fsr_failed_attempts }

let decode_fusion_evidence ~run_id json =
  let* fe_post_id = required_string_field json "id" in
  let* fe_title = required_string_field json "title" in
  let* origin = required_object_field json "origin" in
  let* source = required_string_field origin "source" in
  let* origin_run_id = required_string_field origin "fusion_run_id" in
  let* () =
    if String.equal source "fusion" then Ok ()
    else
      Error
        (Printf.sprintf "fusion evidence origin.source is %S, expected \"fusion\""
           source)
  in
  let* () =
    if String.equal origin_run_id run_id then Ok ()
    else
      Error
        (Printf.sprintf
           "fusion evidence origin run id is %S, expected %S" origin_run_id
           run_id)
  in
  let* meta = required_object_field json "meta" in
  let* fe_question = required_string_field meta "question" in
  let* panel_json = required_list_field meta "panel" in
  let* fe_panel = decode_list "panel" decode_fusion_panel_result panel_json in
  let* judge_json = required_object_field meta "judge" in
  let* fe_judge = decode_fusion_judge judge_json in
  let* fe_judges =
    (* The sink writes the array on every post (fusion_sink.ml, the meta
       encoder), so an absent key is a shape this decoder does not know. *)
    let* nodes = required_list_field meta "judges" in
    decode_list "judges" decode_fusion_judge_node nodes
  in
  let* tool_trace_json = required_object_field meta "tool_trace" in
  let* fe_tool_trace = decode_fusion_tool_trace tool_trace_json in
  let* fe_seat_routes =
    (* A post whose meta has no [seat_routes] key was written before seats
       were recorded; the key, when present, is the sink's whole array. *)
    match member "seat_routes" meta with
    | `Null -> Ok None
    | `List routes ->
        let* routes = decode_list "seat_routes" decode_fusion_seat_route routes in
        Ok (Some routes)
    | bad -> field_type_error "seat_routes" "an array" bad
  in
  Ok
    { fe_post_id
    ; fe_title
    ; fe_question
    ; fe_panel
    ; fe_judge
    ; fe_judges
    ; fe_tool_trace
    ; fe_seat_routes
    }

let decode_fusion_historical_detail ~reference json =
  let* post = match Json_util.assoc_member_opt "post" json with
    | None -> Ok json
    | Some (`Assoc _ as post) -> Ok post
    | Some bad -> field_type_error "post" "an object" bad
  in
  let* post_id = required_string_field post "id" in
  let* origin = required_object_field post "origin" in
  let* source = required_string_field origin "source" in
  let* run_id = required_string_field origin "fusion_run_id" in
  let* () =
    if String.equal post_id reference.fhe_post_id
       && String.equal run_id reference.fhe_run_id && String.equal source "fusion"
    then Ok () else Error "historical Fusion Board identity does not match the selected run and post"
  in
  let* fhd_author = required_string_field post "author" in
  let* fhd_title = required_string_field post "title" in
  let* fhd_body = required_string_field post "body" in
  let fhd_observations =
    let* meta = required_object_field post "meta" in
    let* usage = match Json_util.assoc_member_opt "observed_usage" meta with
    | None -> Ok None
    | Some usage ->
        let* input = required_nonnegative_int_field usage "input_tokens" in
        let* output = required_nonnegative_int_field usage "output_tokens" in
        Ok (Some (input, output))
  in
  let* cost_usd = match Json_util.assoc_member_opt "cost_usd" meta with
    | None | Some `Null -> Ok None
    | Some (`Int n) when n >= 0 -> Ok (Some (float_of_int n))
    | Some (`Float n) when Float.is_finite n && n >= 0. -> Ok (Some n)
    | Some bad -> field_type_error "cost_usd" "a finite nonnegative number or null" bad
  in
    Ok (usage, cost_usd)
  in
  Ok { fhd_reference = reference; fhd_author; fhd_title; fhd_body; fhd_observations;
       fhd_evidence = decode_fusion_evidence ~run_id post }

let decode_fusion_detail json =
  let* fud_generated_at = required_string_field json "generated_at" in
  let* run_json = required_object_field json "run" in
  let* fud_run = decode_fusion_run run_json in
  let* evidence = required_object_field json "evidence" in
  let* status = required_string_field evidence "status" in
  let* post =
    match Json_util.assoc_member_opt "post" evidence with
    | None -> missing_field "post"
    | Some post -> Ok post
  in
  match status, post with
  | "recorded", (`Assoc _ as post_json) ->
      let* fud_evidence =
        decode_fusion_evidence ~run_id:fud_run.fur_run_id post_json
      in
      Ok
        { fud_generated_at
        ; fud_run
        ; fud_evidence_status = Fusion_evidence_recorded
        ; fud_evidence = Some fud_evidence
        }
  | "recorded", bad ->
      field_type_error "evidence.post" "an object when status is recorded" bad
  | "pending", `Null ->
      (match fud_run.fur_status with
       | Fusion_running ->
           Ok
             { fud_generated_at
             ; fud_run
             ; fud_evidence_status = Fusion_evidence_pending
             ; fud_evidence = None
             }
       | Fusion_completed | Fusion_failed _ ->
           Error "only a running fusion run may have pending evidence")
  | "pending", _ -> Error "pending fusion evidence must carry post:null"
  | "absent", `Null ->
      (match fud_run.fur_status with
       | Fusion_running ->
           Error "a running fusion run cannot have absent evidence"
       | Fusion_completed | Fusion_failed _ ->
           Ok
             { fud_generated_at
             ; fud_run
             ; fud_evidence_status = Fusion_evidence_absent
             ; fud_evidence = None
             })
  | "absent", _ -> Error "absent fusion evidence must carry post:null"
  | other, _ -> Error (Printf.sprintf "unknown fusion evidence status %S" other)

(* What the launch form offers, from [GET /api/v1/runtime/config/fusion]:
   the preset names and the one the tool applies when none is named. Only
   the names are read; the panels and judges behind them are the server's. *)
type fusion_launch_options =
  { flo_enabled : bool
  ; flo_default_preset : string
  ; flo_presets : string list
  }

let decode_fusion_launch_options json =
  let* config = required_object_field json "config" in
  let* flo_enabled = required_bool_field config "enabled" in
  let* flo_default_preset = required_string_field config "default_preset" in
  let* presets = required_list_field config "presets" in
  let* flo_presets =
    decode_list "presets" (fun preset -> required_string_field preset "name") presets
  in
  Ok { flo_enabled; flo_default_preset; flo_presets }

(* The answer to [POST /api/v1/keepers/<keeper>/fusion]: a refusal travels
   as a 4xx and never reaches here, so a 2xx body that says [ok:false] is a
   shape this reader does not know rather than a refusal to report. *)
let decode_fusion_launch_receipt json =
  let* ok = required_bool_field json "ok" in
  if ok then required_string_field json "run_id"
  else Error "fusion launch answered 2xx with ok:false"
