module Exact_output = Agent_core.Exact_output

(* The leaf renderers live in AGENT_CORE next to the types they render
   (#27861), so a new constructor fails to compile there instead of being
   re-classified here. This module adds only what AGENT_CORE cannot: the
   redacted raw-body excerpt and the masc log-line labels. *)
let execution_cause_detail = Exact_output.execution_error_cause_to_string
let flow_evidence_detail = Exact_output.flow_evidence_to_string
let candidate_rejection_detail = Exact_output.candidate_rejection_to_string
let attempt_start_error_detail = Exact_output.start_attempt_error_to_string
let measurement_start_error_detail = Exact_output.measurement_start_error_to_string

(* Log lines are single-line records; the excerpt bound keeps one failed call
   from flooding them while the sha256 keeps the full body identifiable in
   wire captures. Provider bodies can echo prompt, memory, or credential
   material, so the excerpt passes through [Observability_redact.redact_text]
   before any truncation — cutting first could split a secret across the
   boundary where the redactor no longer matches it. The cut itself lands on
   a UTF-8 character boundary so the log line stays valid UTF-8 for the log
   ring and its JSON serialization. Byte count and sha256 always describe
   the original wire body, not the redacted excerpt. *)
let raw_response_excerpt_max_bytes = 240

let raw_response_excerpt = function
  | None -> "raw_response=none"
  | Some (raw : Exact_output.raw_response) ->
    let flattened =
      String.map
        (fun char ->
           if Char.equal char '\n' || Char.equal char '\r' then ' ' else char)
        raw.body
    in
    let redacted = Observability_redact.redact_text flattened in
    if String.length redacted <= raw_response_excerpt_max_bytes
    then Printf.sprintf "raw_response=%s" redacted
    else
      Printf.sprintf
        "raw_response=%s... (%d bytes total sha256=%s)"
        (String_util.utf8_prefix
           ~max_bytes:raw_response_excerpt_max_bytes
           redacted)
        (String.length raw.body)
        raw.body_sha256
;;

let execution_error_detail (error : Exact_output.execution_error) =
  Printf.sprintf
    "call_id=%s cause=%s %s"
    (Exact_output.call_id_to_string error.call_id)
    (execution_cause_detail error.cause)
    (raw_response_excerpt error.raw_response)
;;

let execution_failure_detail
      ~(candidate : Exact_output.flow_attempt_receipt)
      ~cause
      ~evidence
  =
  Printf.sprintf
    "slot=%s %s; flow=[%s]"
    candidate.visit.identity.candidate_id
    (execution_error_detail cause)
    (flow_evidence_detail evidence)
;;

let candidates_exhausted_detail ~rejection ~evidence =
  Printf.sprintf
    "%s; flow=[%s]"
    (candidate_rejection_detail rejection)
    (flow_evidence_detail evidence)
;;

let attempt_start_failure_detail
      (candidate : Exact_output.flow_candidate_visit)
      cause
      evidence
  =
  Printf.sprintf
    "slot=%s cause=%s; flow=[%s]"
    candidate.identity.candidate_id
    (attempt_start_error_detail cause)
    (flow_evidence_detail evidence)
;;

let measurement_start_failure_detail
      (candidate : Exact_output.flow_candidate_visit)
      cause
      evidence
  =
  Printf.sprintf
    "slot=%s cause=%s; flow=[%s]"
    candidate.identity.candidate_id
    (measurement_start_error_detail cause)
    (flow_evidence_detail evidence)
;;

(* One line for a terminal flow error. The static labels stay as prefixes so
   log greps keep working; the payload a branch carries (failing slot, typed
   cause, raw provider body, flow journey) follows the label instead of being
   dropped. The callback arms read "unexpected" because every caller that
   renders through here passes callbacks that cannot fail; a lane whose
   callbacks can fail maps those arms to its own errors first. *)
let flow_execution_error_detail : _ Exact_output.flow_execution_error -> string =
  function
  | Flow_attempt_already_started _ -> "attempt_already_started"
  | Flow_attempt_start_failed { candidate; cause; evidence } ->
    "attempt_start_failed: "
    ^ attempt_start_failure_detail candidate cause evidence
  | Flow_measurement_start_failed { candidate; cause; evidence } ->
    "measurement_start_failed: "
    ^ measurement_start_failure_detail candidate cause evidence
  | Flow_candidates_exhausted { rejection; evidence } ->
    "candidates_exhausted: " ^ candidates_exhausted_detail ~rejection ~evidence
  | Flow_before_measurement_dispatch_callback_failed _
  | Flow_measurement_terminal_callback_failed _
  | Flow_before_dispatch_callback_failed _
  | Flow_before_advance_callback_failed _ -> "unexpected_callback_failure"
  | Flow_exact_execution_failed { candidate; cause; evidence } ->
    "agent_core_execution_failed: "
    ^ execution_failure_detail ~candidate ~cause ~evidence
;;
