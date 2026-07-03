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
  | Some _ | None -> None

(* Concrete example handed to the agent when the anti-rationalization
   gate rejects a completion. Prior form said only "describe actual
   work"; small runtimes retried the same perfunctory notes
   (37 Tool_task completion rejects observed on 2026-04-17/18 in
   <base-path>/.masc/tool_calls). The example shows the expected density:
   what changed, which files, what verification ran. See #8688. *)
let completion_notes_example =
  "Example of accepted notes: 'Added Event_kind.Board variant to \
   lib/workspace/event_kind.{ml,mli}, migrated 8 call-sites in \
   task_state.ml and activity_graph.ml, test_event_kind round-trip \
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


let placeholder_evidence_refs =
  [ "-"; "draft"; "n/a"; "na"; "none"; "null"; "pending"; "tbd"; "todo"; "unknown" ]

let is_placeholder_evidence_ref value =
  let value = value |> String.trim |> String.lowercase_ascii in
  value = "" || List.mem value placeholder_evidence_refs

let non_empty_trimmed_strings values =
  values
  |> List.filter_map (fun value ->
         let value = String.trim value in
         if String.equal value "" then None else Some value)
  |> List.sort_uniq String.compare

(* Raw (uncleaned) evidence sources, shared by the flat [evidence_refs]
   projection and the typed [verification_evidence] split (task-1664) so a new
   source is declared in exactly one place. [required_*] are what the contract
   demands; [submitted_*] are what the agent actually referenced. *)
let required_evidence_sources (task : Masc_domain.task) =
  match task.contract with
  | Some contract -> contract.verify_gate_evidence @ contract.required_evidence
  | None -> []

let submitted_evidence_sources ?(notes = "") ?handoff_context
    ?(submitted_evidence_refs = [])
    (task : Masc_domain.task) =
  let resolved_handoff_context =
    match handoff_context with
    | Some _ -> handoff_context
    | None -> task.handoff_context
  in
  let handoff_refs =
    match resolved_handoff_context with
    | Some hc -> hc.evidence_refs
    | None -> []
  in
  let summary_refs =
    match resolved_handoff_context with
    | Some hc ->
      let trimmed = String.trim hc.summary in
      if String.equal trimmed "" || is_placeholder_evidence_ref trimmed
      then []
      else [ trimmed ]
    | None -> []
  in
  let notes_refs =
    let trimmed = String.trim notes in
    if String.equal trimmed "" || is_placeholder_evidence_ref trimmed
    then []
    else [ trimmed ]
  in
  submitted_evidence_refs @ handoff_refs @ summary_refs @ notes_refs

let clean_evidence_refs refs =
  refs
  |> non_empty_trimmed_strings
  |> List.filter (fun s -> not (is_placeholder_evidence_ref s))

(* Typed concat for the verifier request output (observability only).
   Phase E (RFC-0109 closeout) replaced the substring-classifier filter
   with placeholder-only filtering. Gating decisions belong to
   [Cdal_evidence_gate]. *)
let concrete_verification_evidence_refs ?(notes = "") ?handoff_context
    ?submitted_evidence_refs
    (task : Masc_domain.task) =
  required_evidence_sources task
  @ submitted_evidence_sources ~notes ?handoff_context ?submitted_evidence_refs task
  |> clean_evidence_refs

let verification_evidence_refs_for_task (task : Masc_domain.task) =
  concrete_verification_evidence_refs task

(* task-1664: the flat [evidence_refs] list above concatenates the
   contract-required artifacts with the agent-submitted references, so a
   verifier reading it cannot tell "the contract asked for a PR link" from
   "here is the submitted PR link". The typed split keeps the two roles
   distinct in the verification request; the flat projection above stays
   byte-compatible for existing consumers. *)
type verification_evidence =
  { required_artifacts : string list
  ; submitted_evidence : string list
  }
[@@deriving yojson]

let concrete_verification_evidence ?(notes = "") ?handoff_context
    ?submitted_evidence_refs
    (task : Masc_domain.task) : verification_evidence =
  { required_artifacts = clean_evidence_refs (required_evidence_sources task)
  ; submitted_evidence =
      clean_evidence_refs
        (submitted_evidence_sources
           ~notes
           ?handoff_context
           ?submitted_evidence_refs
           task)
  }

(* JSON object fields for the typed split, spliced into the verification
   request output / board meta / SSE alongside the unchanged [evidence_refs]
   field. Shares the derived [verification_evidence_to_yojson] so the
   serialization tested by the roundtrip is the one production emits. *)
let verification_evidence_fields (evidence : verification_evidence)
  : (string * Yojson.Safe.t) list =
  match verification_evidence_to_yojson evidence with
  | `Assoc fields -> fields
  | _ -> []
