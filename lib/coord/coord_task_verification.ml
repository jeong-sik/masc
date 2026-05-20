(** Verification-evidence helpers for coord task lifecycle,
    extracted from coord_task.ml.

    Pure string/JSON predicates and a small messaging helper used by
    [transition_task_r] when validating submission/verification flows. *)

open Masc_domain

let flatten_lock_result = function
  | Ok result -> result
  | Error e -> Error e

let contains_substring_ci text needle =
  let text = String.lowercase_ascii text in
  let needle = String.lowercase_ascii needle in
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > text_len then false
    else if String.equal (String.sub text idx needle_len) needle then true
    else loop (idx + 1)
  in
  loop 0

let is_placeholder_verification_evidence value =
  let value = value |> String.trim |> String.lowercase_ascii in
  let placeholders =
    [ ""; "-"; "draft"; "n/a"; "na"; "none"; "null"; "pending"; "tbd"; "todo"; "unknown" ]
  in
  List.mem value placeholders

let text_has_verification_artifact_ref text =
  let text = String.trim text in
  let has_github_pull =
    contains_substring_ci text "github.com/"
    && contains_substring_ci text "/pull/"
  in
  let has_pr_shorthand =
    contains_substring_ci text "#"
    && (contains_substring_ci text "pr "
        || contains_substring_ci text "pr:"
        || contains_substring_ci text "pull request")
  in
  let has_explicit_artifact =
    [ "artifact:"; "artifact://"; "file:"; "path:"; "commit:"; "branch:" ]
    |> List.exists (contains_substring_ci text)
  in
  has_github_pull || has_pr_shorthand || has_explicit_artifact

let evidence_ref_has_verification_artifact_ref value =
  let value = String.trim value in
  (not (is_placeholder_verification_evidence value))
  && (text_has_verification_artifact_ref value
      || contains_substring_ci value "github.com/"
      || String.contains value '/'
      || String.contains value '.')

let notes_have_verification_artifact_ref notes =
  let notes = String.trim notes in
  (not (is_placeholder_verification_evidence notes))
  && text_has_verification_artifact_ref notes

let verification_evidence_error_message =
  "submit_for_verification requires verification evidence: include pr_url \
   for the draft PR, a PR # reference, or an explicit \
   artifact/file/path/commit/branch reference in notes."

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
      ( hc.evidence_refs
      , if notes_have_verification_artifact_ref hc.summary then [ hc.summary ] else [] )
    | None -> ([], [])
  in
  let notes_refs =
    if notes_have_verification_artifact_ref notes then [ notes ] else []
  in
  normalized_string_list (contract_refs @ handoff_refs @ summary_refs @ notes_refs)
  |> List.filter evidence_ref_has_verification_artifact_ref

