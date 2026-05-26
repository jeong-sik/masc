type decision =
  | Pass
  | Reject of
      { reason : string
      ; rule_id : string
      ; hint : string
      ; payload_json : Yojson.Safe.t
      }

let rule_id_violated = "cdal_verdict_violated"
let rule_id_inconclusive = "cdal_verdict_inconclusive_incomplete"
let rule_id_missing_verdict = "cdal_verdict_missing"

let string_list_to_json xs = `List (List.map (fun s -> `String s) xs)

(* Project a contract_verdict to a JSON envelope for the operator. The
   shape is stable so log/dashboard consumers can match on it. *)
let payload_of_violated_verdict ~task_id (v : Cdal_types.contract_verdict) =
  `Assoc
    [ "task_id", `String task_id
    ; "verdict_status", `String (Cdal_types.contract_status_to_string v.status)
    ; "run_id", `String v.run_id
    ; "contract_id", `String v.contract_id
    ; "judgment_hash", `String v.judgment_hash
    ; ( "findings"
      , `List (List.map Cdal_types.contract_finding_to_json v.findings) )
    ; ( "completeness_gaps"
      , `List (List.map Cdal_types.completeness_gap_to_json v.completeness_gaps) )
    ]

let payload_of_inconclusive_verdict ~task_id ~required_evidence
    (v : Cdal_types.contract_verdict)
  =
  `Assoc
    [ "task_id", `String task_id
    ; "verdict_status", `String (Cdal_types.contract_status_to_string v.status)
    ; "run_id", `String v.run_id
    ; "contract_id", `String v.contract_id
    ; "judgment_hash", `String v.judgment_hash
    ; "required_evidence_unsatisfied", string_list_to_json required_evidence
    ; ( "completeness_gaps"
      , `List (List.map Cdal_types.completeness_gap_to_json v.completeness_gaps) )
    ]

let reason_of_findings (findings : Cdal_types.contract_finding list) =
  match findings with
  | [] -> "verdict reports Violated with no per-finding detail"
  | _ ->
    let check_ids =
      List.map (fun (f : Cdal_types.contract_finding) -> f.check_id) findings
    in
    Printf.sprintf
      "CDAL verdict is Violated. Failed checks: %s"
      (String.concat ", " check_ids)

let reason_of_inconclusive ~required_evidence
    (v : Cdal_types.contract_verdict)
  =
  let gap_count = List.length v.completeness_gaps in
  Printf.sprintf
    "CDAL verdict is Inconclusive: %d completeness gap(s), %d required \
     evidence entry/entries unsatisfied"
    gap_count
    (List.length required_evidence)

let hint_violated =
  "Address the listed findings in [payload.findings]. Once the underlying \
   checks pass, re-run the contract evaluator before retrying \
   submit_for_verification."

let hint_inconclusive =
  "Supply the entries listed in [payload.required_evidence_unsatisfied] (or \
   close the entries in [payload.completeness_gaps]) and re-run the \
   contract evaluator."

let reason_missing_verdict =
  "CDAL verdict is missing for a contracted task; submit_for_verification \
   requires a typed verdict before workflow evidence is accepted."

let hint_missing_verdict =
  "Two recovery paths: (1) retry keeper_task_done with notes >= 20 chars \
   summarising what changed AND every contract.required_evidence entry \
   mentioned verbatim (this triggers the evidence-based fallback in \
   Cdal_evidence_gate); (2) retry with handoff_context.evidence_refs \
   listing at least one concrete artefact reference (file path, PR \
   number, commit hash, trace id).  Pure-placeholder notes ('done', \
   'ok', etc.) with no required_evidence mention and no handoff \
   evidence_refs keep this gate closed."

(* Heuristic: an "evidence entry" is satisfied when the notes or
   handoff_context.evidence_refs mention a non-placeholder string that
   names it. Only used for the Inconclusive arm of the decision matrix;
   Satisfied/Violated/missing-verdict decisions do not consult this. *)
let evidence_entry_satisfied
    ~notes
    ~(handoff_context : Masc_domain.task_handoff_context option)
    (entry : string)
  =
  let entry_trimmed = String.trim entry in
  if String.equal entry_trimmed "" then true
  else
    let entry_lower = String.lowercase_ascii entry_trimmed in
    let notes_lower = String.lowercase_ascii notes in
    let mentions s =
      let needle = String.lowercase_ascii s in
      let nlen = String.length needle in
      let hlen = String.length notes_lower in
      if nlen = 0 || nlen > hlen then false
      else
        let limit = hlen - nlen in
        let rec loop i =
          if i > limit then false
          else if String.sub notes_lower i nlen = needle then true
          else loop (i + 1)
        in
        loop 0
    in
    let in_notes = mentions entry_lower in
    let in_handoff =
      match handoff_context with
      | None -> false
      | Some hc ->
        List.exists
          (fun ref_ ->
            let r = String.lowercase_ascii (String.trim ref_) in
            r <> "" && r = entry_lower)
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
      (fun ref_ -> String.trim ref_ |> String.length > 0)
      hc.evidence_refs

(* Evidence-based fallback (RFC-0109 Phase E-1 / B-lite): when the CDAL
   verdict ledger has no entry for a contracted task but the keeper has
   supplied substantive evidence (all required_evidence entries mentioned,
   plus either non-placeholder notes or a handoff pr_url / evidence_refs),
   treat the gate as Pass.  Rationale: the upstream LLM may have failed
   to emit a typed [Cdal_proof.t] in the turn result (the only path that
   triggers [Cdal_eval_v1.persist] in {!Keeper_agent_run_finalize_response}),
   but the human-readable evidence the keeper *did* attach is sufficient
   for the verifier keeper / human reviewer to inspect downstream.  This
   replaces the prior dead-end where keeper_task_done → Submit redirect
   → verdict missing Reject formed an unrecoverable loop with no
   keeper-actionable path forward (logged 2026-05-27 fleet runtime).

   Returns [true] only when *every* required_evidence entry from the
   contract is mentioned in notes/handoff AND the keeper supplied at
   least one of: substantive notes, handoff.pr_url, handoff.evidence_refs.
   Empty notes with empty required_evidence still rejects, since that
   carries no evidence at all. *)
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

let default_lookup ~task_id =
  Cdal_verdict_gate.lookup_latest_verdict ~warn_on_missing:false ~task_id ()

let decide
    ?(lookup = default_lookup)
    ~task_id
    ~task_opt
    ~notes
    ~handoff_context
    ()
  =
  match lookup ~task_id with
  | Some (v : Cdal_types.contract_verdict) ->
    (match v.status with
     | Cdal_types.Satisfied -> Pass
     | Cdal_types.Violated ->
       let payload_json = payload_of_violated_verdict ~task_id v in
       Reject
         { reason = reason_of_findings v.findings
         ; rule_id = rule_id_violated
         ; hint = hint_violated
         ; payload_json
         }
     | Cdal_types.Inconclusive ->
       let task_contract =
         match (task_opt : Masc_domain.task option) with
         | Some t -> t.contract
         | None -> None
       in
       let unsatisfied =
         unsatisfied_required_evidence
           ~notes
           ~handoff_context
           task_contract
       in
       let has_completeness_gaps = v.completeness_gaps <> [] in
       if (not has_completeness_gaps) && unsatisfied = []
       then Pass
       else
         let payload_json =
           payload_of_inconclusive_verdict
             ~task_id
             ~required_evidence:unsatisfied
             v
         in
         Reject
           { reason = reason_of_inconclusive ~required_evidence:unsatisfied v
           ; rule_id = rule_id_inconclusive
           ; hint = hint_inconclusive
           ; payload_json
           })
  | None ->
    (match (task_opt : Masc_domain.task option) with
     | Some t when Option.is_some t.contract ->
       if evidence_is_substantive ~notes ~handoff_context t.contract
       then Pass
       else
         Reject
           { reason = reason_missing_verdict
           ; rule_id = rule_id_missing_verdict
           ; hint = hint_missing_verdict
           ; payload_json =
               `Assoc
                 [ "task_id", `String task_id
                 ; "contract_required", `Bool true
                 ; "verdict_status", `String "missing"
                 ; ( "evidence_summary"
                   , evidence_summary_payload ~notes ~handoff_context )
                 ]
           }
     | _ ->
       (* Analysis-only task bypass: a task with no contract has nothing to
          verify, so the gate must not block keeper_task_done. This is the
          RFC-0109 §6.5.2 row that directly fixes the operator-visible
          open-loop block for masc-improver-style keepers. *)
       Pass)
