(** Verification-evidence helpers for task lifecycle,
    extracted from task_state.ml.

    Legacy substring classifiers that rejected empty or analysis-only
    submissions at the transition layer are retired.

    Evidence refs are now collected by typed concat from contract metadata,
    handoff context, and non-empty source strings. They are forwarded to
    [Verification_protocol.create_submit_request]
    as observability metadata only. Completion judgment belongs to the LLM
    reviewer at the Task boundary. *)

open Masc_domain
include Workspace_state

let flatten_lock_result = function
  | Ok result -> result
  | Error e -> Error e

let verification_submission_evidence_refs task ~notes handoff_context =
  let contract_refs =
    match task.contract with
    | Some c -> c.verify_gate_evidence @ c.required_evidence
    | None -> []
  in
  let handoff_refs, summary_refs =
    match
      match handoff_context with
      | Some _ -> handoff_context
      | None -> task.handoff_context
    with
    | Some (hc : Masc_domain.task_handoff_context) ->
      let summary_trimmed = String.trim hc.summary in
      let summary_keep =
        if String.equal summary_trimmed "" then [] else [ summary_trimmed ]
      in
      (hc.evidence_refs, summary_keep)
    | None -> ([], [])
  in
  let notes_refs =
    let trimmed = String.trim notes in
    if String.equal trimmed "" then [] else [ trimmed ]
  in
  Workspace_state.normalized_string_list (contract_refs @ handoff_refs @ summary_refs @ notes_refs)
