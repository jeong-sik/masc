(** Verification_protocol -- Cross-agent verification workflow orchestration.

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
      (* task-1664: [required_artifacts] / [submitted_evidence] JSON fields
         spliced next to the flat [evidence_refs] so verifiers can tell the
         contract's demanded artifacts apart from what the agent submitted. *)
  }

let submit_request_spec ~(config : Workspace.config) ~(task : Masc_domain.task)
    ~assignee ~evidence_refs =
  let request_kind, request_summary, next_action, board_type, board_title, board_content =
    match Masc_task_handlers.Planning_eio.load config ~task_id:task.id with
    | Ok plan_ctx
      when Task_completion_claim.deliverable_claims_completion ~task_id:task.id
             plan_ctx.deliverable ->
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
     | None -> []) in
  (* task-1664: derive the typed required/submitted split from the task (the
     SSOT), and splice it next to the unchanged flat [evidence_refs] field. *)
  let evidence_fields =
    Masc_task_handlers.Tool_task_completion_review.verification_evidence_fields
      (Masc_task_handlers.Tool_task_completion_review.concrete_verification_evidence
         ~submitted_evidence_refs:evidence_refs
         task)
  in
  let output =
    `Assoc
      ([ ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
         ("task_title", `String task.title);
         ("request_kind", `String request_kind);
         ("request_summary", `String request_summary);
         ("next_action", `String next_action);
       ]
       @ evidence_fields)
  in
  { criteria
  ; output
  ; request_kind
  ; request_summary
  ; next_action
  ; board_type
  ; board_title
  ; board_content
  ; evidence_fields
  }

let warn_contract_gap (task : Masc_domain.task) =
  (* Observability for #8272: tasks submitted without a contract land in
     storage with empty completion_contract + empty evidence, which the
     dashboard renders as "—". Surface this as a warn so operators can
     trace the gap back to the task creation site instead of only
     noticing it in the UI. No behavior change. *)
  (match task.contract with
   | None ->
     Log.Task.warn
       ~keeper_name:task.id
       "[verification-submit] task=%s has no contract — completion_contract \
        and evidence will be empty in the verification record"
       task.id
   | Some c
     when c.completion_contract = []
          && c.required_evidence = []
          && c.verify_gate_evidence = [] ->
     Log.Task.warn
       ~keeper_name:task.id
       "[verification-submit] task=%s has a contract but both \
       completion_contract and verification evidence are empty"
       task.id
   | Some _ -> ())

let create_submit_request ~(config : Workspace.config)
    ~(task : Masc_domain.task) ~assignee ~verification_id ~evidence_refs =
  let base_path = config.Workspace.base_path in
  warn_contract_gap task;
  let spec = submit_request_spec ~config ~task ~assignee ~evidence_refs in
  match
    Verification.create_request ~base_path ~task_id:task.id ~request_id:verification_id
      ~output:spec.output ~criteria:spec.criteria ~worker:assignee ()
  with
  | Ok _ -> Ok ()
  | Error e ->
    Log.Task.error
      ~keeper_name:task.id
      "verification create_request failed (task=%s vrf=%s): %s"
      task.id verification_id e;
    Error e

(* RFC-0221 §3.1: compensation for atomic submit. Remove the verification record
   for [verification_id] when the task_status commit it was written for did not
   land, so the record store and [task_status] are never left disagreeing.
   Mirrors {!create_submit_request}'s base_path derivation. A missing record is
   success (idempotent), so compensation is safe to run unconditionally. *)
let delete_verification_request ~(config : Workspace.config) ~verification_id =
  let base_path = config.Workspace.base_path in
  match Verification.delete_request base_path verification_id with
  | Ok () -> Ok ()
  | Error e ->
    Log.Task.error
      ~keeper_name:verification_id
      "verification delete_request failed (vrf=%s): %s"
      verification_id e;
    Error e

let notify_submit_for_verification ~(config : Workspace.config)
    ~(task : Masc_domain.task) ~assignee ~verification_id ~evidence_refs =
  let spec = submit_request_spec ~config ~task ~assignee ~evidence_refs in
  let meta_json = `Assoc ([
    ("type", `String spec.board_type);
    ("task_id", `String task.id);
    ("verification_id", `String verification_id);
    ("worker", `String assignee);
    ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
    ("criteria", `List (List.map Verification.criterion_to_yojson spec.criteria));
    ("request_kind", `String spec.request_kind);
    ("next_action", `String spec.next_action);
  ] @ spec.evidence_fields) in
  let () =
    match Board_dispatch.create_post
      ~author:"system"
      ~content:spec.board_content
      ~title:spec.board_title
      ~post_kind:Board.System_post
      ~meta_json
      ~visibility:Board.Internal
      ~hearth:"verification"
      ()
    with
    | Ok _ -> ()
    | Error e ->
      Log.Task.error
        ~keeper_name:task.id
        "board post failed (task=%s vrf=%s): %s"
        task.id verification_id (Board_types.show_board_error e)
  in
  Subscriptions.push_event_to_sessions (`Assoc ([
    ("type", `String "masc/verification/requested");
    ("task_id", `String task.id);
    ("verification_id", `String verification_id);
    ("worker", `String assignee);
    ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
    ("timestamp", `Float (Time_compat.now ()));
  ] @ spec.evidence_fields));
  ()

let on_submit_for_verification ~(config : Workspace.config)
    ~(task : Masc_domain.task) ~assignee ~verification_id ~evidence_refs =
  match create_submit_request ~config ~task ~assignee ~verification_id ~evidence_refs with
  | Error e -> Error e
  | Ok () ->
    notify_submit_for_verification ~config ~task ~assignee ~verification_id ~evidence_refs;
    Ok ()

let record_approve_verification ~(config : Workspace.config)
    ~task_id ~verifier ~verification_id ~notes =
  let base_path = config.Workspace.base_path in
  (* Update Verification.ml state machine: Pending -> Completed Pass.
     Issue #7544. *)
  if verification_id = "" then
    Error "verification_id is required for approval verdict persistence"
  else
    match
      Verification.submit_verdict
        ~base_path
        ~req_id:verification_id
        ~verifier
        ~verdict:Verification.Pass
    with
    | Ok updated ->
      Verification.attribution_of_request updated
      |> Option.iter Dashboard_attribution.record;
      Ok ()
    | Error e ->
      Log.Task.error
        ~keeper_name:task_id
        "verification submit_verdict failed (task=%s vrf=%s verifier=%s): %s"
        task_id verification_id verifier e;
      Error e

let notify_approve_verification ~task_id ~verifier ~verification_id ~notes =
  let meta_json = `Assoc [
    ("type", `String "verification_verdict");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verdict", `String "approved");
  ] in
  let () =
    match Board_dispatch.create_post
      ~author:verifier
      ~content:(Printf.sprintf "Approved task %s (vrf:%s)%s"
        task_id verification_id
        (if notes = "" then "" else " — " ^ notes))
      ~post_kind:Board.System_post
      ~meta_json
      ~visibility:Board.Internal
      ~hearth:"verification"
      ()
    with
    | Ok _ -> ()
    | Error e ->
      Log.Task.error
        ~keeper_name:task_id
        "board post failed (task=%s vrf=%s): %s"
        task_id verification_id (Board_types.show_board_error e)
  in
  Subscriptions.push_event_to_sessions (`Assoc [
    ("type", `String "masc/verification/verdict");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verifier", `String verifier);
    ("verdict", `String "approved");
    ("notes", `String notes);
    ("timestamp", `Float (Time_compat.now ()));
  ])

let on_approve_verification ~(config : Workspace.config)
    ~task_id ~verifier ~verification_id ~notes =
  match
    record_approve_verification ~config ~task_id ~verifier ~verification_id ~notes
  with
  | Error e -> Error e
  | Ok () ->
    notify_approve_verification ~task_id ~verifier ~verification_id ~notes;
    Ok ()

let record_reject_verification ~(config : Workspace.config)
    ~task_id ~verifier ~verification_id ~reason =
  let base_path = config.Workspace.base_path in
  (* Update Verification.ml state machine: Pending -> Completed (Fail reason).
     Issue #7544. *)
  if verification_id = "" then
    Error "verification_id is required for rejection verdict persistence"
  else
    match
      Verification.submit_verdict
        ~base_path
        ~req_id:verification_id
        ~verifier
        ~verdict:(Verification.Fail reason)
    with
    | Ok updated ->
      Verification.attribution_of_request updated
      |> Option.iter Dashboard_attribution.record;
      Ok ()
    | Error e ->
      Log.Task.error
        ~keeper_name:task_id
        "verification submit_verdict failed (task=%s vrf=%s verifier=%s): %s"
        task_id verification_id verifier e;
      Error e

let notify_reject_verification ~task_id ~verifier ~verification_id ~reason =
  let meta_json = `Assoc [
    ("type", `String "verification_verdict");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verdict", `String "rejected");
  ] in
  let () =
    match Board_dispatch.create_post
      ~author:verifier
      ~content:(Printf.sprintf "Rejected task %s (vrf:%s): %s"
        task_id verification_id reason)
      ~post_kind:Board.System_post
      ~meta_json
      ~visibility:Board.Internal
      ~hearth:"verification"
      ()
    with
    | Ok _ -> ()
    | Error e ->
      Log.Task.error
        ~keeper_name:task_id
        "board post failed (task=%s vrf=%s): %s"
        task_id verification_id (Board_types.show_board_error e)
  in
  Subscriptions.push_event_to_sessions (`Assoc [
    ("type", `String "masc/verification/rejected");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verifier", `String verifier);
    ("reason", `String reason);
    ("timestamp", `Float (Time_compat.now ()));
  ])

let on_reject_verification ~(config : Workspace.config)
    ~task_id ~verifier ~verification_id ~reason =
  match
    record_reject_verification ~config ~task_id ~verifier ~verification_id ~reason
  with
  | Error e -> Error e
  | Ok () ->
    notify_reject_verification ~task_id ~verifier ~verification_id ~reason;
    Ok ()

let awaiting_verification_deadline
      ~(submitted_at : string)
      ~(deadline : string option)
  =
  match deadline with
  | Some deadline ->
    (match Masc_domain.parse_iso8601_opt deadline with
     | Some deadline_ts -> Some ("deadline", deadline, deadline_ts)
     | None -> None)
  | None ->
    (match Masc_domain.parse_iso8601_opt submitted_at with
     | Some submitted_ts ->
       let deadline_ts =
         submitted_ts +. Env_config_runtime.Verification.timeout_deadline_seconds ()
       in
       Some
         ( "submitted_at_fallback"
         , Masc_domain.iso8601_of_unix_seconds deadline_ts
         , deadline_ts )
     | None -> None)

(* RFC-0220 §5: the destructive 24h verification deadline rescue is removed.
   With the verification sub-state folded into [task_status] (RFC-0220 §3.1),
   the illegal Todo+Pending drift is unrepresentable, an AwaitingVerification
   obligation stays claimable by a verifier, and a keeper never idles on an
   empty pool — so the per-obligation wall-clock deadline this enforced (the
   I2-forbidden heuristic) is unnecessary, and its destructive force-cancel
   discarded work rather than rescheduling the obligation. Long-waiting
   obligations are surfaced from the activity-event stream, not a poll-timer.
   Neutered here in PR-1 (forced by dropping [deadline] from the type); the
   [verification_timeout] fork and these knobs are deleted in a follow-up
   (RFC-0220 §11 PR-3). *)
let check_timeouts ~(config : Workspace.config) =
  let _ = config in
  ()
;;
