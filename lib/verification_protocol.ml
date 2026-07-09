*** Verification_protocol -- Cross-agent verification workflow orchestration.

    Bridges task FSM transitions (AwaitingVerification state) with:
    - Board system (Direct visibility posts to verifiers)
    - SSE events (masc:verification:requested, :verdict, :rejected)
    - Verification storage (.masc/verifications/)

    @since Phase B+C *)

(* Fail-closed by types: [~assignee] is passed directly by the caller,
   which already destructures [AwaitingVerification { assignee; _ }]. Removes
   the prior "unknown" fallback that violated Silent Failure 금지. Issue #7547.

   Contract source rules (must stay aligned with [task_contract] in
   types_core.ml):
   - [criteria]: the operator-facing "must be true" statements →
     [task.contract.completion_contract] wrapped in [Verification.Custom].
   - [evidence_refs]: the artefact list the verifier expects to see →
     [task.contract.verify_gate_evidence] plus required evidence refs,
     passed in by the caller at task-state lifecycle so this function does
     not reach into task.contract twice for different fields. *)

type submit_request_spec =
  { criteria : Verification.criterion list
  ; output : Yojson.Safe.t
  ; request_kind : string
  ; request_summary : string
  ; next_action : string
  ; board_type : string
  ; board_title : string
  ; board_content : string
  ; evidence_fields : (string * Yojson.Safe.t) list
  }

let first_line text =
  match String.index_opt text '\n' with
  | Some i -> String.sub text 0 i
  | None -> text

let deliverable_claims_completion ~task_id deliverable =
  let normalized =
    deliverable
    |> String.trim
    |> String.lowercase_ascii
    |> first_line
  in
  normalized <> ""
  && (String.starts_with
        ~prefix:(String.lowercase_ascii task_id ^ " completed")
        normalized
      || String.starts_with ~prefix:"completed" normalized)

let submit_request_spec ~(config : Workspace.config) ~(task : Masc_domain.task)
    ~assignee ~evidence_refs =
  let request_kind, request_summary, next_action, board_type, board_title, board_content =
    match Masc_task_handlers.Planning_eio.load config ~task_id:task.id with
    | Ok plan_ctx
      when deliverable_claims_completion ~task_id:task.id plan_ctx.deliverable ->
      ( "conflict_triage",
        "Conflict verification required: board / planning / mutation path disagree.",
        "Reconcile board / planning / mutation surfaces before ordinary approval.",
        "verification_conflict_request",
        Printf.sprintf "Conflict verify: %s" task.title,
        Printf.sprintf
          "Conflict verification required for task %s (%s) by %s. Do not approve as ordinary merged-PR verification; reconcile board / planning / mutation surfaces first."
          task.id task.title assignee )
    | Ok _ | Error _ ->
      ( "normal",
        "",
        "",
        "verification_request",
        Printf.sprintf "Verify: %s" task.title,
        Printf.sprintf "Verification requested for task %s (%s) by %s"
          task.id task.title assignee )
  in
  let criteria = List.map (fun s -> Verification.Custom s)
      (match task.contract with
      | Some c -> c.completion_contract
      | None -> [])
  in
  let evidence_fields =
    Masc_task_handlers.Tool_task_completion_review.verification_evidence_fields
      (Masc_task_handlers.Tool_task_completion_review.concrete_verification_evidence
        ~submitted_evidence_refs:evidence_refs
        task)
  in
  let output =
    `Assoc
    ([ ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
       ("request_kind", `String request_kind);
       ("next_action", `String next_action);
       ("board_type", `String board_type);
       ("board_title", `String board_title);
       ("board_content", `String board_content);
       ("criteria", `List (List.map (fun (Verification.Custom s) -> `String s) criteria));
       (("evidence_fields", `List (List.map (fun (k, v) -> `Assoc [`String k`; v]) evidence_fields));
    ])
  in
  { criteria; output; request_kind; request_summary; next_action; board_type; board_title; board_content; evidence_fields }

let record_approve_verification
  ~config ~task_id ~verifier ~verification_id ~notes =
  (* task-1880: Pre-flight evidence validation -- reject empty evidence_refs )
  if notes = "" || String.trim notes = "" then
    Error "Approval notes are required; provide evidence references and a summary of what was verified"
  else
    let result =
      (* Original FSM transition )
      Verification.transition ~config
        ~task_id
        ~verifier
        ~verification_id
        ~action:Approve
        ~notes
    in
    match result with
    | Ok () -> Ok ()
    | Error msg -> Error msg

let record_reject_verification
  ~config ~task_id ~verifier ~verification_id ~notes =
  (* task-1880: Pre-flight evidence validation -- reject empty evidence_refs )
  if notes = "" || String.trim notes = "" then
    Error "Rejection notes are required; provide evidence references and a summary of what was missing"
  else
    let result =
      (* Original FSM transition )
      Verification.transition ~config
        ~task_id
        ~verifier
        ~verification_id
        ~notes
        ~action:Reject
    in
    match result with
    | Ok () -> Ok ()
    | Error msg -> Error msg

