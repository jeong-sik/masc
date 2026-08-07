(** Tool_task_completion_review — verification-evidence projections for task
    tools.

    Pure helpers (no IO, no [context]).

    @since God file decomposition — extracted from tool_task.ml *)

(* RFC-0337 decision 4: shared element-level predicate for evidence-ref
   boundary checks. The masc_transition handoff boundary rejects entries
   this predicate flags instead of silently dropping them; the
   keeper_task_done parser (keeper_tool_task_runtime.ml) enforces the same
   semantics locally on raw JSON for keeper-vocabulary error messages. *)
let blank_evidence_ref value = String.equal (String.trim value) ""

(* The same boundary rule, one step further: an entry the verification store
   cannot read is refused where the caller can still fix it, instead of being
   snapshotted as [Evidence_invalid_reference] and surfacing later as a
   reviewer REJECT the submitter cannot act on. Live case (2026-08-05):
   task-174 resubmitted the same `board:p-…` reference and was rejected 59
   times in two hours before one approval — 49% of every rejection the
   completion authority issued. The shape decision stays the store's; this is
   a call into it, not a second copy of the accepted prefixes. *)
let unresolvable_evidence_ref value =
  match
    Workspace_verification_store.classify_evidence_reference (String.trim value)
  with
  | Workspace_verification_store.Unresolvable_reference -> true
  | Workspace_verification_store.Artifact_reference _
  | Workspace_verification_store.Note_reference _ -> false
;;

let resolvable_evidence_ref_forms =
  String.concat " or " Workspace_verification_store.resolvable_reference_forms
;;

let note_evidence_ref_form = Workspace_verification_store.note_reference_form

let non_empty_trimmed_strings values =
  values
  |> List.filter_map (fun value ->
         if blank_evidence_ref value then None else Some (String.trim value))
  |> List.sort_uniq String.compare

let note_evidence_ref = Workspace_task_verification.note_evidence_ref

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
      Option.to_list (note_evidence_ref trimmed)
    | None -> []
  in
  let notes_refs =
    let trimmed = String.trim notes in
    Option.to_list (note_evidence_ref trimmed)
  in
  submitted_evidence_refs @ handoff_refs @ summary_refs @ notes_refs

let clean_evidence_refs = non_empty_trimmed_strings

(* task-1664: the flat projection that used to sit here concatenated the
   contract-required artifacts with the agent-submitted references, so a
   verifier reading it could not tell "the contract asked for a PR link" from
   "here is the submitted PR link". This typed split keeps the two roles
   distinct in the verification request.

   The flat one was kept afterwards for byte-compatibility with existing
   consumers. It had none -- no caller inside this module or outside it -- so
   it is gone. *)
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
   serialization tested by the roundtrip is the one production emits.

   That roundtrip is [test_verification] / "verification_evidence wire", which
   states the wire object as a literal and checks this function against it. It
   is named here because the sentence above claimed a test that did not exist
   until it was written. *)
let verification_evidence_fields (evidence : verification_evidence)
  : (string * Yojson.Safe.t) list =
  match verification_evidence_to_yojson evidence with
  | `Assoc fields -> fields
  | _ -> []
