(** Verification-evidence helpers for task lifecycle,
    extracted from task_state.ml.

    Legacy substring classifiers that rejected empty or analysis-only
    submissions at the transition layer are retired.

    Evidence refs are collected from the producer's typed handoff refs.
    Narrative summaries are represented explicitly as [note:] evidence so the
    persisted snapshot cannot confuse a completion note with an artifact.
    Contract requirements are projected separately by
    [Verification_protocol.create_submit_request]. Completion judgment belongs
    to the system LLM reviewer at the Task boundary. *)

open Masc_domain
include Workspace_state

let flatten_lock_result = function
  | Ok result -> result
  | Error e -> Error e

let note_evidence_ref value =
  let trimmed = String.trim value in
  if String.equal trimmed ""
  then None
  else if String.starts_with ~prefix:"note:" trimmed
  then Some trimmed
  else Some ("note:" ^ trimmed)

let verification_submission_evidence_refs task ~notes handoff_context =
  let handoff_refs, summary_refs =
    match
      match handoff_context with
      | Some _ -> handoff_context
      | None -> task.handoff_context
    with
    | Some (hc : Masc_domain.task_handoff_context) ->
      let summary_trimmed = String.trim hc.summary in
      let summary_keep = Option.to_list (note_evidence_ref summary_trimmed) in
      (hc.evidence_refs, summary_keep)
    | None -> ([], [])
  in
  let notes_refs =
    Option.to_list (note_evidence_ref notes)
  in
  Workspace_state.normalized_string_list (handoff_refs @ summary_refs @ notes_refs)
