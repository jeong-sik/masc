module Exact_output = Agent_core.Exact_output

(* [Flow_exact_execution_failed] is the branch that carries the provider's own
   verdict. The typed cause alone ("completion failed") says nothing about
   which provider said what; the raw response body carried next to it does. *)
let execution_cause_detail : Exact_output.execution_error_cause -> string = function
  | Attempt_already_started -> "attempt already started"
  | Clock_required_for_timeout -> "clock required for timeout"
  | Frozen_request_mismatch -> "frozen request mismatch"
  | Completion_failed -> "completion failed"
  | Provider_response_refused { http_status; refusal } ->
    Printf.sprintf
      "provider refused (http_status=%d refusal=%s)"
      http_status
      (Exact_output.provider_refusal_to_string refusal)
  | Incomplete_output -> "incomplete output"
  | Missing_output -> "missing output"
  | Ambiguous_output count -> Printf.sprintf "ambiguous output (candidates=%d)" count
  | Unexpected_output_content -> "unexpected output content"
  | Invalid_json_output -> "invalid json output"
  | Internal_non_json_output -> "internal non-json output"
;;

(* [flow_evidence] is a private agent-core type with no constructor outside agent core,
   so the assembled line cannot be built in a test. The part that decides what
   the line says is split out here, where it can. That gap is why the label
   collapse below survived: the leaf renderer [execution_cause_detail] was
   covered, and the caller that failed to use it was not. *)
let advance_failure_kind : Exact_output.flow_advance_failure_snapshot -> string * string
  = function
  | Exact_output.Flow_advance_candidate_rejected rejection ->
    (Exact_output.candidate_rejection_identity rejection).candidate_id, "candidate_rejected"
  (* [execution_error_cause] distinguishes eleven outcomes — a quota refusal,
     an output budget spent before the answer, invalid JSON, an HTTP refusal
     with its status. Rendering only "execution_failed" collapsed all eleven
     into one label, and this advance is the only place a losing slot is
     recorded: it left no other trace, so "why did the first slot lose the
     run" had no answer anywhere. Observed 2026-08-07: the librarian advanced
     off glm-coding.glm-5-turbo eight times and the cause was recoverable from
     neither the log nor the call id. *)
  | Exact_output.Flow_advance_execution_failed { candidate; cause; raw_response_sha256 } ->
    let sha =
      match raw_response_sha256 with
      | None -> ""
      | Some sha -> Printf.sprintf " raw_response_sha256=%s" sha
    in
    ( candidate.visit.identity.candidate_id
    , Printf.sprintf "execution_failed cause=%s%s" (execution_cause_detail cause) sha )
;;

let flow_evidence_detail (evidence : Exact_output.flow_evidence) =
  let attempts =
    List.map
      (fun (attempt : Exact_output.flow_attempt_snapshot) ->
      Printf.sprintf
        "slot=%s call_id=%s"
        attempt.visit.identity.candidate_id
        (Exact_output.generation_receipt_snapshot_call_id attempt.receipt
         |> Exact_output.call_id_to_string))
      evidence.attempts
  in
  let advances =
    List.map
      (fun (advance : Exact_output.flow_advance_receipt) ->
         let failed_slot, failure_kind = advance_failure_kind advance.failed in
         Printf.sprintf
           "advance=%s->%s kind=%s"
           failed_slot
           advance.next.identity.candidate_id
           failure_kind)
      evidence.advances
  in
  match attempts @ advances with
  | [] -> "no candidate attempt or advance was recorded"
  | details -> String.concat "; " details
;;

let optional_tokens = function
  | None -> "unknown"
  | Some tokens -> string_of_int tokens
;;

(* A capacity refusal happens before any request leaves this process, and the
   receipt carries the typed reason with its token arithmetic. Discarding it
   is what makes a local capacity refusal indistinguishable from a provider
   outage in the durable row. Matched exhaustively so that a new AGENT_CORE
   disposition is a compile error here rather than an unexplained failure
   label in production. *)
let rec capacity_disposition_detail : Exact_output.input_capacity_disposition -> string
  = function
  | Token_measurement_required { accepted_through_tokens; rejected_from_tokens } ->
    Printf.sprintf
      "token measurement required (accepted_through=%d rejected_from=%s)"
      accepted_through_tokens
      (optional_tokens rejected_from_tokens)
  | Context_window_exceeded { input_tokens; reserved_output_tokens; max_context_tokens } ->
    Printf.sprintf
      "context window exceeded (input=%d reserved_output=%d max_context=%d)"
      input_tokens
      reserved_output_tokens
      max_context_tokens
  | Token_capacity_rejected rejection -> token_capacity_detail rejection
  | Serialized_request_body_too_large _ ->
    "serialized request body too large"

and token_capacity_detail : Exact_output.token_capacity_rejection -> string = function
  | Capacity_evidence_not_yet_valid { now_unix_s; checked_at_unix_s } ->
    Printf.sprintf
      "capacity evidence not yet valid (now=%d checked_at=%d)"
      now_unix_s
      checked_at_unix_s
  | Capacity_evidence_expired { now_unix_s; expires_at_unix_s } ->
    Printf.sprintf
      "capacity evidence expired (now=%d expires_at=%d)"
      now_unix_s
      expires_at_unix_s
  | Capacity_boundary_unknown { input_tokens; accepted_through_tokens; rejected_from_tokens }
    ->
    Printf.sprintf
      "capacity boundary unknown (input=%d accepted_through=%d rejected_from=%s)"
      input_tokens
      accepted_through_tokens
      (optional_tokens rejected_from_tokens)
  | Capacity_input_rejected { input_tokens; accepted_through_tokens; rejected_from_tokens }
    ->
    Printf.sprintf
      "capacity input rejected (input=%d accepted_through=%d rejected_from=%d)"
      input_tokens
      accepted_through_tokens
      rejected_from_tokens
;;

let rejection_disposition_detail : Exact_output.candidate_rejection_disposition -> string
  = function
  | Runtime_slot_unavailable -> "runtime slot unavailable"
  | Runtime_contract_rejected -> "runtime contract rejected"
  | Input_contract_rejected -> "input contract rejected"
  | Output_requirement_rejected -> "output requirement rejected"
  | Input_capacity disposition -> capacity_disposition_detail disposition
  | Request_preparation_failed -> "request preparation failed"
;;

let candidate_rejection_detail (rejection : Exact_output.candidate_rejection_receipt) =
  Printf.sprintf
    "slot=%s %s"
    (Exact_output.candidate_rejection_identity rejection).candidate_id
    (Exact_output.candidate_rejection_disposition rejection
     |> rejection_disposition_detail)
;;


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
