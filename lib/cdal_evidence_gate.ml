type decision =
  | Pass
  | Reject of
      { reason : string
      ; rule_id : string
      ; hint : string
      ; payload_json : Yojson.Safe.t
      }

let rule_id_evidence_incomplete = "cdal_evidence_incomplete"

let hint_evidence_incomplete =
  "Supply task-completion evidence: notes >= 20 chars summarising what \
   changed AND every contract.required_evidence entry mentioned verbatim, \
   OR at least one handoff_context.evidence_refs reference (PR number, commit \
   hash, trace id, or reviewer-inspectable URL). Pure-placeholder \
   notes ('done', 'ok', etc.) with no required_evidence mention and no \
   handoff evidence_refs keep this gate closed."

let reason_evidence_incomplete ~required_evidence =
  Printf.sprintf
    "Task-completion evidence is insufficient: %d required evidence \
     entry/entries unsatisfied and no substantive notes or handoff \
     reference supplied"
    (List.length required_evidence)

let evidence_ref_is_gate_trusted ref_ =
  match Evidence_ref.of_string ref_ with
  | Some (Evidence_ref.Url _ | Evidence_ref.Pr _ | Evidence_ref.Commit _ | Evidence_ref.Trace_ref _) -> true
  | Some (Evidence_ref.File_uri _ | Evidence_ref.File_path _) ->
    (* File-shaped refs are only shape-recognized by [Evidence_ref]. Without a
       base-path/artifact-store resolution step they are candidates, not proof a
       reviewer can inspect. Fail closed until a validated file evidence type is
       available. *)
    false
  | None -> false

let notes_mention_required_entry ~notes entry =
  let needle = String.lowercase_ascii entry in
  let haystack = String.lowercase_ascii notes in
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 || needle_len > haystack_len then false
  else
    let limit = haystack_len - needle_len in
    let rec loop i =
      if i > limit then false
      else if
        String.sub haystack i needle_len = needle
        && Evidence_ref.boundary_match ~haystack ~needle ~start:i
      then true
      else loop (i + 1)
    in
    loop 0

(* Heuristic: an "evidence entry" is satisfied when the notes or
   concrete handoff_context.evidence_refs mention a non-placeholder string that
   names it. Blank required entries are never evidence. *)
let evidence_entry_satisfied
    ~notes
    ~(handoff_context : Masc_domain.task_handoff_context option)
    (entry : string)
  =
  let entry_trimmed = String.trim entry in
  if String.equal entry_trimmed "" then false
  else
    let entry_lower = String.lowercase_ascii entry_trimmed in
    let in_notes = notes_mention_required_entry ~notes entry_lower in
    let in_handoff =
      match handoff_context with
      | None -> false
      | Some hc ->
        List.exists
          (fun ref_ ->
            let r = String.lowercase_ascii (String.trim ref_) in
            evidence_ref_is_gate_trusted ref_ && r = entry_lower)
          hc.evidence_refs
    in
    in_notes || in_handoff

let unsatisfied_required_evidence
    ~notes
    ~handoff_context
    (contract : Masc_domain.task_contract option)
  =
  match contract with
  | None -> []
  | Some c ->
    List.filter
      (fun e -> not (evidence_entry_satisfied ~notes ~handoff_context e))
      c.required_evidence

let task_has_contract (task_opt : Masc_domain.task option) =
  match task_opt with
  | None -> false
  | Some t -> Option.is_some t.contract

(* Placeholder note bodies that {!evidence_is_substantive} treats as
   "keeper supplied nothing".  Compared on the trimmed lowercase form.
   This is deliberately conservative: the goal is to recognise clearly
   empty / null-equivalent done messages, not to second-guess substantive
   prose. *)
let placeholder_note_bodies =
  [ ""
  ; "done"
  ; "ok"
  ; "complete"
  ; "completed"
  ; "draft"
  ; "pending"
  ; "n/a"
  ; "na"
  ; "tbd"
  ; "todo"
  ]

let notes_are_substantive (notes : string) : bool =
  let trimmed = String.trim notes |> String.lowercase_ascii in
  if List.exists (String.equal trimmed) placeholder_note_bodies then false
  else String.length trimmed >= 20

let handoff_supplies_evidence
    (handoff_context : Masc_domain.task_handoff_context option) : bool =
  match handoff_context with
  | None -> false
  | Some hc ->
    List.exists
      evidence_ref_is_gate_trusted
      hc.evidence_refs

(* Evidence-substantiveness gate for explicit verification submissions. Normal
   task completion is LLM-reviewed before it reaches [Done]; this gate only
   checks that a caller putting a task into AwaitingVerification supplied
   evidence a reviewer can inspect downstream. A contracted task passes when
   *every* required_evidence entry is mentioned in notes/handoff AND the caller
   supplied at least one of: substantive notes, or a handoff evidence reference
   (PR number, commit hash, trace id, or reviewer-inspectable URL). Empty
   notes with empty required_evidence still rejects, since that carries no
   evidence at all. *)
let evidence_is_substantive
    ~notes
    ~(handoff_context : Masc_domain.task_handoff_context option)
    (contract : Masc_domain.task_contract option) : bool =
  match contract with
  | None -> false
  | Some c ->
    let required_evidence_satisfied =
      unsatisfied_required_evidence ~notes ~handoff_context (Some c) = []
    in
    let any_evidence_supplied =
      notes_are_substantive notes || handoff_supplies_evidence handoff_context
    in
    required_evidence_satisfied && any_evidence_supplied

let evidence_summary_payload
    ~(notes : string)
    ~(handoff_context : Masc_domain.task_handoff_context option) : Yojson.Safe.t =
  `Assoc
    [ "notes_length", `Int (String.length (String.trim notes))
    ; ( "handoff_evidence_refs_count"
      , `Int
          (match handoff_context with
           | None -> 0
           | Some hc -> List.length hc.evidence_refs) )
    ]

let decide ~task_id ~task_opt ~notes ~handoff_context () =
  match (task_opt : Masc_domain.task option) with
  | Some t when Option.is_some t.contract ->
    (* TASK-1887 HOTFIX: disable Gate 0 (evidence_is_substantive) until the
       call site is wired (task-1889). PR #23666 added this branch and the
       contract-aware reject path, but tool_task_handlers.ml still passes
       `evidence_refs = []` for every task submission, so every keeper_task_done
       hit the REJECT path and could not close. Always Pass here so the gate
       does not block legitimate completions; the contract-required evidence
       check will be re-enabled in the task-1889 follow-up once the call site
       populates evidence_refs. *)
    let _evidence_substantive =
      evidence_is_substantive ~notes ~handoff_context t.contract
    in
    let unsatisfied =
      unsatisfied_required_evidence ~notes ~handoff_context t.contract
    in
    Log.Task.info
      "cdal_evidence_gate PASS_DISABLED task=%s unsatisfied=%d notes_len=%d handoff_refs=%d (task-1887 hotfix; gate disabled until call site wired)"
      task_id
      (List.length unsatisfied)
      (String.length (String.trim notes))
      (match handoff_context with None -> 0 | Some hc -> List.length hc.evidence_refs);
    Pass
  | _ ->
    (* Analysis-only task bypass: a task with no contract has nothing to
       verify, so the gate must not block keeper_task_done. *)
    Pass
