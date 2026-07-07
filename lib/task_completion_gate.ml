type decision =
  | Pass
  | Reject of
      { reason : string
      ; rule_id : string
      ; hint : string
      ; payload_json : Yojson.Safe.t
      }

(* Retained rule id. The gate historically lived in [Cdal_evidence_gate]; the
   string is asserted by downstream tests and consumed offline by the
   completion-trust audit, so it is kept stable across the RFC-0311 rewrite.
   RFC-0311 §5 typed rejection reasons are a later phase. *)
let rule_id_evidence_incomplete = "cdal_evidence_incomplete"

(* Payload token naming the one thing every rejected completion is missing: a
   trusted, reviewer-inspectable reference on handoff_context.evidence_refs.
   Tests assert this literal in the reject payload. *)
let missing_evidence_ref_token = "handoff_context.evidence_refs"

let reason_evidence_incomplete =
  "Task-completion evidence is insufficient: no trusted, reviewer-inspectable \
   evidence reference was supplied. Completion notes alone do not satisfy the \
   gate."

let hint_evidence_incomplete =
  "Attach at least one trusted handoff_context.evidence_refs reference: a PR \
   number (PR#123), a commit hash, a trace id (trace:/turn:/receipt:), or a \
   reviewer-inspectable URL. Completion notes and file paths are not accepted \
   as proof — a file-shaped reference is not inspectable without base-path \
   resolution."

(* L1 core: an evidence reference is gate-trusted only when it parses to a
   reviewer-inspectable Evidence_ref shape (URL / PR / commit / trace id).
   File-shaped refs (File_uri / File_path) are shape-recognized but not proof a
   reviewer can inspect without base-path/artifact-store resolution, so they
   fail closed. *)
let evidence_ref_is_gate_trusted ref_ =
  match Evidence_ref.of_string ref_ with
  | Some (Evidence_ref.Url _ | Evidence_ref.Pr _ | Evidence_ref.Commit _ | Evidence_ref.Trace_ref _) ->
    true
  | Some (Evidence_ref.File_uri _ | Evidence_ref.File_path _) -> false
  | None -> false

let handoff_supplies_trusted_ref
    (handoff_context : Masc_domain.task_handoff_context option) : bool =
  match handoff_context with
  | None -> false
  | Some hc -> List.exists evidence_ref_is_gate_trusted hc.evidence_refs

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

let reject_payload ~task_id ~contract_required ~notes ~handoff_context : Yojson.Safe.t =
  `Assoc
    [ "task_id", `String task_id
    ; "contract_required", `Bool contract_required
    ; ( "required_evidence_unsatisfied"
      , `List [ `String missing_evidence_ref_token ] )
    ; "evidence_summary", evidence_summary_payload ~notes ~handoff_context
    ]

(* RFC-0311 Phase 1 (L1, universal default): a task completion is accepted iff
   the caller supplies at least one trusted, reviewer-inspectable evidence
   reference on handoff_context.evidence_refs. Completion [notes] are IGNORED
   for the pass/fail decision — they cannot be inspected and were the substring
   surface that previously let BOTH over-blocking (unknown keepers rejected) and
   fake-done (labels pasted to pass) through the same line. The contract's
   [required_evidence] descriptive entries are likewise not consulted here (they
   still feed the anti-rationalization reviewer prompt and verifier records);
   binding completion to specific evidence KINDS is RFC-0311 Phase 2. A missing
   live task fails closed. *)
let decide ~task_id ~task_opt ~notes ~handoff_context () =
  let handoff_refs_count =
    match (handoff_context : Masc_domain.task_handoff_context option) with
    | None -> 0
    | Some hc -> List.length hc.evidence_refs
  in
  match (task_opt : Masc_domain.task option) with
  | None ->
    (* Fail closed: there is no live task to verify. The sole production caller
       already rejects a missing task before reaching the gate, so this branch
       is defense-in-depth, not a keeper-visible path. *)
    Log.Task.warn "task_completion_gate REJECT task=%s reason=no_live_task rule=%s"
      task_id rule_id_evidence_incomplete;
    Reject
      { reason = "Task-completion evidence gate reached with no live task."
      ; rule_id = rule_id_evidence_incomplete
      ; hint = hint_evidence_incomplete
      ; payload_json =
          reject_payload ~task_id ~contract_required:false ~notes ~handoff_context
      }
  | Some t ->
    if handoff_supplies_trusted_ref handoff_context
    then begin
      Log.Task.info "task_completion_gate PASS task=%s notes_len=%d handoff_refs=%d"
        task_id (String.length (String.trim notes)) handoff_refs_count;
      Pass
    end
    else begin
      Log.Task.warn
        "task_completion_gate REJECT task=%s notes_len=%d handoff_refs=%d rule=%s"
        task_id (String.length (String.trim notes)) handoff_refs_count
        rule_id_evidence_incomplete;
      Reject
        { reason = reason_evidence_incomplete
        ; rule_id = rule_id_evidence_incomplete
        ; hint = hint_evidence_incomplete
        ; payload_json =
            reject_payload ~task_id
              ~contract_required:(Option.is_some t.contract)
              ~notes ~handoff_context
        }
    end
