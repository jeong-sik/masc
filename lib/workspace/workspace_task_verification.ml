(** Verification-evidence helpers for task lifecycle,
    extracted from task_state.ml.

    Phase D (RFC-0109 #18715) routed contracted submissions through the
    typed [Task_completion_gate] decision. Phase E (this module rewrite)
    retires the legacy substring-classifier predicates that used to
    reject empty/analysis-only submissions at the transition layer.

    Evidence refs are now collected by typed concat from contract
    metadata, handoff context, and a non-empty/non-placeholder notes
    string. They are forwarded to [Verification_protocol.create_submit_request]
    as observability metadata only — the gating decision lives in
    [Task_completion_gate]. *)

open Masc_domain
include Workspace_state

let flatten_lock_result = function
  | Ok result -> result
  | Error e -> Error e

let is_placeholder_verification_evidence value =
  let value = value |> String.trim |> String.lowercase_ascii in
  let placeholders =
    [ ""; "-"; "draft"; "n/a"; "na"; "none"; "null"; "pending"; "tbd"; "todo"; "unknown" ]
  in
  List.mem value placeholders

(* Declared refs only — contract metadata plus the typed handoff channel.
   Free-text summary/notes are excluded on purpose: they are observability,
   and an evidence gate that counted arbitrary prose would be vacuous. *)
let declared_verification_evidence_refs (task : Masc_domain.task) handoff_context =
  let contract_refs =
    match task.contract with
    | Some c -> c.verify_gate_evidence @ c.required_evidence
    | None -> []
  in
  let handoff_refs =
    match
      (match handoff_context with
       | Some _ -> handoff_context
       | None -> task.handoff_context)
    with
    | Some (hc : Masc_domain.task_handoff_context) -> hc.evidence_refs
    | None -> []
  in
  Workspace_state.normalized_string_list (contract_refs @ handoff_refs)
  |> List.filter (fun s -> not (is_placeholder_verification_evidence s))

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
        if String.equal summary_trimmed ""
           || is_placeholder_verification_evidence summary_trimmed
        then []
        else [ summary_trimmed ]
      in
      (hc.evidence_refs, summary_keep)
    | None -> ([], [])
  in
  let notes_refs =
    let trimmed = String.trim notes in
    if String.equal trimmed ""
       || is_placeholder_verification_evidence trimmed
    then []
    else [ trimmed ]
  in
  Workspace_state.normalized_string_list (contract_refs @ handoff_refs @ summary_refs @ notes_refs)
  |> List.filter (fun s -> not (is_placeholder_verification_evidence s))
