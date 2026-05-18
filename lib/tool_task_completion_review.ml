(** Tool_task_completion_review — completion-notes review helpers and
    verification-evidence predicates for task tools.

    Pure helpers (no IO, no [context]). The [Tool_task] facade composes
    these with context-bound side effects (Sse.broadcast,
    Eval_calibration record, anti-rationalization invocation).

    @since God file decomposition — extracted from tool_task.ml *)

let can_review_completion ~(task_opt : Masc_domain.task option) ~(agent_name : string) =
  match task_opt with
  | Some task ->
      (match task.task_status with
       | Masc_domain.Claimed { assignee; _ }
       | Masc_domain.InProgress { assignee; _ } ->
           String.equal assignee agent_name
       | Masc_domain.Todo
       | Masc_domain.AwaitingVerification _
       | Masc_domain.Done _
       | Masc_domain.Cancelled _ -> false)
  | None -> false

let persisted_completion_contract ~(task_opt : Masc_domain.task option) =
  match task_opt with
  | Some ({ contract = Some contract; _ } : Masc_domain.task)
    when Stdlib.List.length contract.completion_contract > 0 ->
      Some contract.completion_contract
  | _ -> None

(* Concrete example handed to the keeper when the anti-rationalization
   gate rejects a completion. Prior form said only "describe actual
   work"; small-LLM keepers retried the same perfunctory notes
   (37 Tool_task completion rejects observed on 2026-04-17/18 in
   <base-path>/.masc/tool_calls). The example shows the expected density:
   what changed, which files, what verification ran. See #8688. *)
let completion_notes_example =
  "Example of accepted notes: 'Added Event_kind.Board variant to \
   lib/coord/event_kind.{ml,mli}, migrated 8 call-sites in \
   coord_task.ml and activity_graph.ml, test_event_kind round-trip \
   green, CI green on PR #NNNN.'"

let completion_rejection_message ?(allow_force = false) reason =
  if allow_force then
    Printf.sprintf
      "Completion rejected by anti-rationalization gate: %s\n\
       Revise your completion notes to describe actual work, then retry.\n\
       %s\n\
       Use force=true to override (operator only)." reason completion_notes_example
  else
    Printf.sprintf
      "Completion rejected by anti-rationalization gate: %s\n\
       Revise your completion notes to describe actual work, then retry.\n\
       %s" reason completion_notes_example

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

let placeholder_evidence_refs =
  [ "-"; "draft"; "n/a"; "na"; "none"; "null"; "pending"; "tbd"; "todo"; "unknown" ]

let is_placeholder_evidence_ref value =
  let value = value |> String.trim |> String.lowercase_ascii in
  value = "" || List.mem value placeholder_evidence_refs

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

let pr_url_has_pull_ref pr_url =
  let pr_url = String.trim pr_url in
  (not (is_placeholder_evidence_ref pr_url))
  && ((contains_substring_ci pr_url "github.com/"
       && contains_substring_ci pr_url "/pull/")
      || (contains_substring_ci pr_url "#"
          && (contains_substring_ci pr_url "pr "
              || contains_substring_ci pr_url "pr:"
              || contains_substring_ci pr_url "pull request")))

let artifact_like_ref value =
  let value = String.trim value in
  contains_substring_ci value "artifact://"
  || contains_substring_ci value "file:"
  || contains_substring_ci value "path:"
  || contains_substring_ci value "commit:"
  || contains_substring_ci value "branch:"
  || contains_substring_ci value "github.com/"
  || String.contains value '/'
  || String.contains value '.'

let evidence_ref_has_verification_artifact_ref value =
  let value = String.trim value in
  (not (is_placeholder_evidence_ref value))
  && (text_has_verification_artifact_ref value || artifact_like_ref value)

let notes_have_verification_artifact_ref notes =
  let notes = String.trim notes in
  (not (is_placeholder_evidence_ref notes))
  && text_has_verification_artifact_ref notes

let non_empty_trimmed_strings values =
  values
  |> List.filter_map (fun value ->
         let value = String.trim value in
         if String.equal value "" then None else Some value)
  |> List.sort_uniq String.compare

let handoff_context_has_verification_artifact_ref = function
  | Some (handoff_context : Masc_domain.task_handoff_context) ->
      handoff_context.evidence_refs |> non_empty_trimmed_strings |> fun refs ->
      List.exists evidence_ref_has_verification_artifact_ref refs
  | None -> false

let verification_submission_evidence_error ~notes ~handoff_context =
  if notes_have_verification_artifact_ref notes
     || handoff_context_has_verification_artifact_ref handoff_context
  then None
  else
    Some
      "submit_for_verification requires verification evidence: include pr_url \
       for the draft PR, a PR # reference, or an explicit \
       artifact/file/path/commit/branch reference in notes."

let verification_evidence_refs_for_task (task : Masc_domain.task) =
  let contract_refs =
    match task.contract with
    | Some contract -> contract.verify_gate_evidence
    | None -> []
  in
  let handoff_refs =
    match task.handoff_context with
    | Some handoff_context -> handoff_context.evidence_refs
    | None -> []
  in
  non_empty_trimmed_strings (contract_refs @ handoff_refs)
