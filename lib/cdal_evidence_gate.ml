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
let rule_id_substring_fallback = "submit_verification_missing_evidence"

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

(* Reuses the existing substring-shim message verbatim so operator-facing
   error text matches the legacy gate when the fallback path triggers. *)
let hint_substring_fallback =
  Tool_task_completion_review.verification_evidence_error_message

(* Heuristic: an "evidence entry" is satisfied when the notes or
   handoff_context.evidence_refs mention a non-placeholder string that
   names it (substring match). This mirrors the legacy substring shim's
   placeholder rejection. Only used for the Inconclusive arm of the
   decision matrix; Satisfied/Violated do not consult this. *)
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

let default_lookup ~task_id =
  Cdal_verdict_gate.lookup_latest_verdict ~warn_on_missing:false ~task_id ()

let substring_fallback ~notes ~handoff_context =
  match
    Tool_task_completion_review.verification_submission_evidence_error
      ~notes
      ~handoff_context
  with
  | None -> Pass
  | Some reason ->
    Reject
      { reason
      ; rule_id = rule_id_substring_fallback
      ; hint = hint_substring_fallback
      ; payload_json = `Null
      }

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
    if task_has_contract task_opt
    then substring_fallback ~notes ~handoff_context
    else
      (* Analysis-only task bypass: a task with no contract has nothing to
         verify, so the gate must not block keeper_task_done. This is the
         RFC-0109 §6.5.2 row that directly fixes the operator-visible
         open-loop block for masc-improver-style keepers. *)
      Pass
