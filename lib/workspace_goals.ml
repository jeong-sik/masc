(** Workspace_goals - Handlers for goal management tools. *)

open Workspace_types
open Tool_args

(* Handlers return [Tool_result.result] (RFC-0189 PR-1b.8). A failure is
   built by [Tool_args.error_result_typed] or [Tool_args.validation_error_result],
   which take the class from the error code. A goal store this build cannot
   read answers through [Goal_unavailable_envelope] (RFC-0444 PR-2). *)
let ok_result ~tool_name ~start_time fields : Tool_result.result =
  Tool_result.make_ok ~tool_name ~start_time ~data:(ok_assoc fields) ()
;;

let unavailable_result = Goal_unavailable_envelope.tool_result
;;

(* RFC-0089: derive the accepted-value sets from the Goal_phase ADT (the goal
   lifecycle SSOT) instead of hand-rolling them here, so the validator, the MCP
   schema enum, and the type can never drift apart. *)
let goal_phase_strings = List.map Goal_phase.Kind.to_string Goal_phase.Kind.all

let goal_transition_action_strings =
  List.map Goal_phase.Public_action.to_string Goal_phase.Public_action.all
;;

let make_enum_field_error ~field ~allowed ~received =
  { field
  ; constraint_violated = One_of allowed
  ; message = Printf.sprintf "%s must be one of: %s" field (String.concat ", " allowed)
  ; expected = Some (String.concat "|" allowed)
  ; received = Some received
  }
;;

let make_type_field_error ~field ~constraint_violated ~expected ~received =
  { field
  ; constraint_violated
  ; message = Printf.sprintf "%s must be a %s" field expected
  ; expected = Some expected
  ; received = Some received
  }
;;

let parse_optional_goal_phase args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some (`String raw) when String.trim raw = "" -> Ok None
  | Some (`String raw) ->
    (match Goal_phase.Kind.parse raw with
     | Some phase -> Ok (Some phase)
     | None ->
       Error (make_enum_field_error ~field ~allowed:goal_phase_strings ~received:raw))
  | Some json ->
    Error
      (make_type_field_error
         ~field
         ~constraint_violated:Type_string
         ~expected:"string"
         ~received:(Yojson.Safe.to_string json))
;;

let reject_retired_goal_list_status args =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt "status" fields with
     | None -> Ok ()
     | Some json ->
       Error
         { field = "status"
         ; constraint_violated = One_of goal_phase_strings
         ; message = "status filter was removed from masc_goal_list; use phase"
         ; expected = Some "phase"
         ; received = Some (Yojson.Safe.to_string json)
         })
  | _ -> Ok ()
;;

let goal_upsert_lifecycle_error ~tool_name ~start_time field =
  error_result_typed
    ~tool_name
    ~start_time
    ~code:Validation_error
    (Printf.sprintf
       "masc_goal_upsert does not accept lifecycle field %s; use masc_goal_transition"
       field)
;;

let parse_optional_priority args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some (`Int n) ->
    if n < 1 || n > 5
    then
      Error
        { field
        ; constraint_violated = Min_int 1
        ; message = "priority must be between 1 and 5"
        ; expected = Some "1..5"
        ; received = Some (Int.to_string n)
        }
    else Ok (Some n)
  | Some json ->
    Error
      (make_type_field_error
         ~field
         ~constraint_violated:Type_int
         ~expected:"integer"
         ~received:(Yojson.Safe.to_string json))
;;

let parse_optional_transition_action args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some (`String raw) ->
    (match Goal_phase.Public_action.parse raw with
     | Some action -> Ok (Some action)
     | None ->
       Error
         (make_enum_field_error
            ~field
            ~allowed:goal_transition_action_strings
            ~received:raw))
  | Some json ->
    Error
      (make_type_field_error
         ~field
         ~constraint_violated:Type_string
         ~expected:"string"
         ~received:(Yojson.Safe.to_string json))
;;

let emit_goal_event (ctx : context) ~goal_id ~event_type ~payload =
  match Goal_store.append_audit_event_after_pending ctx.config
    (`Assoc
       [ "ts", `String (Masc_domain.now_iso ())
       ; "goal_id", `String goal_id
       ; "event_type", `String event_type
       ; "payload", payload
       ]) with
  | Ok () -> ()
  | Error detail -> raise (Sys_error detail)
;;

let goal_event_recording_to_yojson delivery (event : Goal_store.pending_event) =
  let fields = match delivery with
    | Ok () -> [ "status", `String "recorded" ]
    | Error detail ->
        [ "status", `String "failed"; "error", `String detail;
          "payload", event.payload; "durable_retry", `Bool true ] in
  `Assoc (("event_type", `String (Goal_store.event_kind_to_string event.kind))
          :: ("event_id", `String event.event_id) :: fields)
;;

(* RFC-0387 stage 2: wake the goal verifier lane after a durable
   [Proof_pending] request committed. The wake is
   scheduling only — the same discipline as the task-side
   [verification_submitted_fn] call: a raised hook must not fail (or roll
   back) a commit that already landed. A repeated [request_complete] on a
   standing [Proof_pending] request sends the explicit event-driven wake
   again. *)
let notify_goal_verification_pending (ctx : context) ~goal_id =
  try
    (Atomic.get Workspace_hooks.goal_verification_pending_fn) ctx.config ~goal_id
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Misc.error
      "goal verification wake degraded after durable request commit goal_id=%s detail=%s"
      goal_id
      (Printexc.to_string exn)
;;

(* An operator Drop or Reopen moved the Goal. A verifier review still running
   for it can no longer commit, so the lane cancels it and frees its slot. *)
let notify_goal_verification_abandoned (ctx : context) ~goal_id =
  try
    (Atomic.get Workspace_hooks.goal_verification_abandoned_fn) ctx.config ~goal_id
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Misc.error
      "goal verification abandon failed after the phase write goal_id=%s detail=%s"
      goal_id
      (Printexc.to_string exn)
;;

let handle_goal_list ~tool_name ~start_time (ctx : context) args : Tool_result.result =
  match
    ( reject_retired_goal_list_status args
    , parse_optional_goal_phase args "phase" )
  with
  | Error err, _ | _, Error err ->
    validation_error_result ~tool_name ~start_time [ err ]
  | Ok (), Ok phase ->
    match Goal_store.list_goals_result ctx.config ?kind:phase () with
    (* RFC-0444 criterion 1: a store this build cannot read is the typed
       envelope, never [goals:[]]. [Uninitialized] reads as [Ok []]. *)
    | Error unavailable -> unavailable_result ~tool_name ~start_time unavailable
    | Ok goals ->
    let rollup = Goal_store.compute_rollup goals in
    (* RFC-0387 (stage 1): the verification ledger joins each goal here (not
       in [Goal_store.goal_to_yojson], which is the persistence codec). The
       ledger is loaded ONCE per request and joined in memory; a store that
       does not decode renders the explicit [ledger_error] marker per goal —
       never the pre-verification default, which would disguise corruption as
       "not verified yet". *)
    let records = Goal_verification.load_records_authoritative ctx.config in
    let measurements = Goal_measurement.load ctx.config in
    let goal_json (goal : Goal_store.goal) =
      let verification =
        match records with
        | Error detail -> Goal_verification.ledger_error_to_yojson detail
        | Ok records ->
          (match
             List.find_opt
               (fun (record : Goal_verification.record) ->
                 String.equal record.goal_id goal.id)
               records
           with
           | Some record -> record
           | None -> Goal_verification.default_record ~goal_id:goal.id)
          |> Goal_verification.record_to_yojson_for_goal ~goal
      in
      match Goal_store.goal_to_yojson goal with
      | `Assoc fields ->
          `Assoc (fields @ [ "verification", verification
                           ; "measurement", Goal_measurement.projection measurements goal ])
      | json -> json
    in
    ok_result
      ~tool_name
      ~start_time
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "count", `Int (List.length goals)
      ; "goals", `List (List.map goal_json goals)
      ; "rollup", Goal_store.rollup_to_yojson rollup
      ]
;;
(* "Supplied" follows this module's optional-field convention: a missing key,
   an explicit [null], and a blank string all count as not supplied — the same
   three shapes the removed [parse_optional_goal_status] mapped to [Ok None].
   Anything else is a lifecycle value the caller meant to set. *)
let goal_upsert_lifecycle_field_supplied args =
  List.find_opt
    (fun field ->
      match Json_util.assoc_member_opt field args with
      | None | Some `Null -> false
      | Some (`String raw) -> String.trim raw <> ""
      | Some _ -> true)
    [ "phase"; "status" ]
;;

let handle_goal_upsert ~tool_name ~start_time (ctx : context) args : Tool_result.result =
  (* Lifecycle fields are rejected as soon as they are supplied, before any value
     validation. Validating the value first answered "in_progress" with the enum
     message "allowed: active, paused, done, dropped", which sent the caller back
     with a value this handler also rejects — two turns to reach one verdict. *)
  match goal_upsert_lifecycle_field_supplied args with
  | Some field -> goal_upsert_lifecycle_error ~tool_name ~start_time field
  | None ->
  match parse_optional_priority args "priority" with
  | Error err -> validation_error_result ~tool_name ~start_time [ err ]
  | Ok priority ->
    let id = get_string_opt args "id" in
    let title = get_string_opt args "title" in
    let metric = get_string_opt args "metric" in
    let target_value = get_string_opt args "target_value" in
    let due_date = get_string_opt args "due_date" in
    (match
          Goal_store.upsert_goal_with_events
            ctx.config ~actor:ctx.agent_name
            ?id
            ?title
            ?metric
            ?target_value
            ?due_date
            ?priority
            ()
        with
        | Error (Goal_store.Rejected msg) ->
          error_result_typed ~tool_name ~start_time ~code:Validation_error msg
        | Error (Goal_store.Store_unavailable unavailable) ->
          unavailable_result ~tool_name ~start_time unavailable
        | Error (Goal_store.Goal_not_found _ as error) ->
          error_result_typed ~tool_name ~start_time ~code:Not_found
            (Goal_store.write_error_to_string error)
        | Error (Goal_store.Persist_failed _ as error) ->
          error_result_typed ~tool_name ~start_time ~code:Internal_error
            (Goal_store.write_error_to_string error)
        | Ok (goal, action, events) ->
          let action_name = match action with
            | `created -> "created" | `updated _ -> "updated" in
          let delivery = Goal_store.flush_pending_events ctx.config in
          (match delivery with
           | Ok () -> ()
           | Error detail ->
               Log.Misc.error "goal audit delivery deferred after durable commit goal_id=%s detail=%s"
                 goal.id detail);
          ok_result
            ~tool_name
            ~start_time
            [ "action", `String action_name
            ; "goal_id", `String goal.id
            ; "goal", Goal_store.goal_to_yojson goal
            ; "event_recordings", `List
                (List.map (goal_event_recording_to_yojson delivery) events)
            ; ( "task_goal_id_example"
              , `String
                  (Printf.sprintf
                     {|masc_add_task({title: "Implement %s", goal_id: "%s"})|}
                     goal.title
                     goal.id) )
            ; "task_link_field", `String "goal_id"
            ; "task_link_mode", `String "structured_goal_id"
            ; ( "linked_task_title_example"
              , `String (Printf.sprintf "[child] %s" goal.title) )
            ])
;;

let handle_goal_measure ~tool_name ~start_time (ctx : context) args
    : Tool_result.result =
  match Goal_measurement.record_json ctx.config ~actor:ctx.agent_name args with
  | Ok measurement ->
      ok_result ~tool_name ~start_time
        [ "measurement", Goal_measurement.to_yojson measurement
        ; "verification", `String "reported_only"
        ]
  | Error error ->
      let code =
        match error with
        | Goal_measurement.Invalid_request _ -> Validation_error
        | Goal_measurement.Conflict _ -> Conflict
        | Goal_measurement.Store_error _ -> Internal_error
      in
      error_result_typed ~tool_name ~start_time ~code
        (Goal_measurement.error_to_string error)
;;

(* RFC-0387 stage 2 — the completion gate.

   Ordering for every gated action: [Goal_phase.decide_transition] first (the
   FSM is the ONLY transition decider), then the ledger commit, then the phase
   write, then the event. The ledger never judges a transition — it records
   durable requests ([mark_*_pending]) and verdicts, and its commit failure
   vetoes the phase write (persist-before-model-call), which is what keeps a
   crashed write reconcilable instead of wedged (stage-2 review P0-2). *)

(* The gate actions carry a verdict; a verdict without evidence is not a
   judgment, so [evidence] is required non-blank (RFC-0387 §3.3/§4). *)
let gate_action_requires_evidence = function
  | Goal_phase.Record_proof_proven
  | Goal_phase.Record_proof_refuted -> true
  | Goal_phase.Confirm_completion
  | Goal_phase.Request_complete
  | Goal_phase.Drop
  | Goal_phase.Reopen | Goal_phase.Pause | Goal_phase.Resume
  | Goal_phase.Block | Goal_phase.Unblock -> false
;;

let validate_gate_evidence args action =
  if not (gate_action_requires_evidence action)
  then Ok ""
  else
    match get_string_opt args "evidence" with
    | Some evidence when String.trim evidence <> "" -> Ok evidence
    | received ->
      Error
        [ { field = "evidence"
          ; constraint_violated = Required
          ; message =
              Printf.sprintf
                "%s requires non-blank evidence — a verdict without evidence \
                 is not a judgment (RFC-0387)"
                (Goal_phase.action_to_string action)
          ; expected = Some "non-blank string"
          ; received
          }
        ]
;;

type verifier_decision =
  | Proof_proven
  | Proof_refuted of { reason : string }

type proof_reconciliation =
  | No_committed_proof
  | Reconciled of Goal_phase.t
  | Reconciliation_not_needed of Goal_phase.t

let validate_verification_run_id verification_run_id =
  if String.trim verification_run_id <> ""
  then Ok verification_run_id
  else
    Error
      [ { field = "verification_run_id"
        ; constraint_violated = Required
        ; message =
            "a verifier verdict must name the exact durable verification run"
        ; expected = Some "non-blank run ID"
        ; received = Some verification_run_id
        }
      ]
;;

(* The authority is constructed inside the application boundary. It is not a
   field accepted from an MCP caller and cannot be replaced by a Keeper/session
   name. [Standalone_lane.to_id Verifier] is the runtime configuration SSOT. *)
let verifier_authority =
  Masc_domain.System_llm_agent
    { agent_run_id = Standalone_lane.to_id Standalone_lane.Verifier }
;;

let gate_verdict
      (outcome : Goal_verification.verdict_outcome)
      ~verification_run_id
      ~request_id
      ~criterion
      ~evidence
    : Goal_verification.verdict
  =
  { Goal_verification.outcome
  ; verification_run_id
  ; request_id
  ; criterion
  ; authority = verifier_authority
  ; evidence
  ; recorded_at = Masc_domain.now_iso ()
  }
;;

(* Freeze the announcement at the phase commit, not at delivery time. It is
   informational even when the quoted title/evidence contains mention syntax. *)
let proof_announcement ~(goal : Goal_store.goal) (verdict : Goal_verification.verdict) =
  let outcome, confirmation = match verdict.outcome with
    | Goal_verification.Proven -> "proven", "human confirmation required"
    | Goal_verification.Refuted {reason} -> "refuted: " ^ reason, "not ready for confirmation" in
  let Goal_store.Criterion {revision;_} = verdict.criterion in
  Printf.sprintf
    "[goal_verdict] %s — %s\nphase: %s\noutcome: %s\n%s\nevidence: %s\nproof: %s / %s\ncriterion: %s\nrecorded_at: %s"
    goal.id goal.title (Goal_phase.to_string goal.phase) outcome confirmation verdict.evidence
    verdict.request_id verdict.verification_run_id revision verdict.recorded_at
;;

let gate_event_payload (ctx : context) ~phase (verdict : Goal_verification.verdict) =
  let outcome_fields =
    match verdict.outcome with
    | Goal_verification.Proven -> [ "outcome", `String "proven" ]
    | Goal_verification.Refuted { reason } ->
      [ "outcome", `String "refuted"; "reason", `String reason ]
  in
  `Assoc
    ([ "phase", Goal_phase.to_yojson phase
     ; "actor", `String ctx.agent_name
     ; "verification_run_id", `String verdict.verification_run_id
     ; "request_id", `String verdict.request_id
     ; "criterion", Goal_store.criterion_to_yojson verdict.criterion
     ; "evidence", `String verdict.evidence
     ; "recorded_at", `String verdict.recorded_at
     ]
     @ outcome_fields)
;;

let proof_effects config (goal : Goal_store.goal) verdict : Goal_store.transition_effects =
  let actor = Standalone_lane.to_id Standalone_lane.Verifier in
  let ctx : context = {config; agent_name=actor} in
  {events=[Goal_store.Phase, gate_event_payload ctx ~phase:goal.phase verdict];
   notifications=[actor, proof_announcement ~goal verdict]}
;;

let no_goal_effects : Goal_store.transition_effects = {events=[]; notifications=[]}

let recorded_proof (record : Goal_verification.record) = match record.completion with
  | Goal_verification.Proof_proven verdict | Proof_refuted verdict | Human_confirmed (verdict, _) -> Ok verdict
  | Completion_idle | Proof_pending _ -> Error "committed proof record has no verdict"
;;

let deliver_goal_effects config =
  match Goal_delivery.flush config with
  | Ok () -> `Assoc ["status", `String "delivered"]
  | Error detail ->
      Log.Misc.warn "Goal effects retained for retry: %s" detail;
      `Assoc ["status", `String "deferred"; "durable_retry", `Bool true; "detail", `String detail]
;;

let already_goal_response ~tool_name ~start_time ~goal_id ~action ~phase goal verification =
  ok_result
    ~tool_name
    ~start_time
    ([ "goal_id", `String goal_id
     ; "action", `String (Goal_phase.action_to_string action)
     ; "noop", `Bool true
     ; "phase", Goal_phase.to_yojson phase
     ; "goal", Goal_store.goal_to_yojson goal
     ]
     @
     match verification with
     | Some (record : Goal_verification.record) ->
       [ "verification", Goal_verification.record_to_yojson_for_goal ~goal record ]
     | None -> [])
;;

let verifier_decision_parts = function
  | Proof_proven ->
    Goal_phase.Record_proof_proven, Goal_verification.Proven, None
  | Proof_refuted { reason } ->
    ( Goal_phase.Record_proof_refuted
    , Goal_verification.Refuted { reason }
    , Some reason )
;;

let goal_after_proof (goal : Goal_store.goal) phase note =
  { goal with phase
  ; last_review_note = note
  ; last_review_at = Some (Masc_domain.now_iso ()) }
;;

type proof_step = Goal_store.goal -> Goal_verification.verdict -> (unit, string) result

type confirmation_step =
  Goal_store.goal
  -> Goal_verification.verdict
  -> Goal_verification.confirmation
  -> (unit, string) result

(* The caller's step runs for a passing verdict only: a refutation sends the
   Goal back to Executing and is not a completion. *)
let run_before_proof_commit step (goal : Goal_store.goal)
    (verdict : Goal_verification.verdict) =
  match step, verdict.Goal_verification.outcome with
  | Some step, Goal_verification.Proven -> step goal verdict
  | Some _, Goal_verification.Refuted _ -> Ok ()
  | None, (Goal_verification.Proven | Goal_verification.Refuted _) -> Ok ()
;;

let commit_verifier_decision ?before_proof_commit ~tool_name ~start_time config
    ~goal_id ~verification_run_id ~request_id ~criterion ~decision ~evidence =
  let action, verdict_outcome, note = verifier_decision_parts decision in
  match validate_verification_run_id verification_run_id,
        validate_gate_evidence (`Assoc [ "evidence", `String evidence ]) action with
  | Error errors, _ | _, Error errors -> validation_error_result ~tool_name ~start_time errors
  | Ok verification_run_id, Ok evidence ->
    let verdict = gate_verdict verdict_outcome ~verification_run_id ~request_id ~criterion ~evidence in
    let effects goal (_, changed, verdict) =
      if changed then proof_effects config goal verdict else no_goal_effects in
    let committed = Goal_store.transact_goal ~effects config ~goal_id (fun goal ->
      if not (Goal_store.criterion_equal criterion (Goal_store.criterion_of_goal goal)) then
        Error "proof criterion has been superseded"
      else
        let persist ~changed phase =
          let open Result.Syntax in
          let before_commit () = run_before_proof_commit before_proof_commit goal verdict in
          let* record = Goal_verification.record_proof_verdict ~before_commit config ~goal_id verdict in
          let* stored = recorded_proof record in
          let updated = if changed then goal_after_proof goal phase note else goal in
          Ok (updated, (record, changed, stored)) in
        match Goal_phase.decide_transition ~phase:goal.phase ~action with
        | Error _ when goal.phase = Goal_phase.Paused Goal_phase.Resume_verifying
                    || goal.phase = Goal_phase.Blocked Goal_phase.Resume_verifying ->
            persist ~changed:false goal.phase
        | Ok (Goal_phase.Move_to phase) -> persist ~changed:true phase
        | Error detail ->
          (* A delivered verdict may be retried after its phase write committed.
             Require the exact stored proof; a same-outcome answer from another
             request or run must never license a replay. *)
          Result.bind (Goal_verification.get_record_authoritative config ~goal_id)
            (function
              | Some ({ Goal_verification.completion =
                  (Goal_verification.Proof_proven stored | Goal_verification.Proof_refuted stored
                   | Goal_verification.Human_confirmed (stored, _)); _ } as record)
                when stored = { verdict with recorded_at = stored.recorded_at }
                  && (match goal.phase, stored.outcome with
                      | (Goal_phase.Awaiting_confirmation | Goal_phase.Completed), Goal_verification.Proven
                      | Goal_phase.Executing, Goal_verification.Refuted _ -> true
                      | _ -> false) -> Ok (goal, (record, false, stored))
              | _ -> Error detail)
        | Ok (Goal_phase.Already _) -> Error "proof verdict did not name a phase transition") in
    (match committed with
     | Error (Goal_store.Store_unavailable unavailable) ->
       unavailable_result ~tool_name ~start_time unavailable
     | Error (Goal_store.Goal_not_found _ | Goal_store.Rejected _
             | Goal_store.Persist_failed _ as error) ->
       error_result_typed ~tool_name ~start_time ~code:Conflict
         (Goal_store.write_error_to_string error)
     | Ok (goal, (record, changed, _)) ->
       let delivery = deliver_goal_effects config in
       ok_result ~tool_name ~start_time
         [ "goal_id", `String goal_id
         ; "action", `String (Goal_phase.action_to_string action)
         ; "noop", `Bool (not changed)
         ; "effect_delivery", delivery
         ; "goal", Goal_store.goal_to_yojson goal
         ; "verification", Goal_verification.record_to_yojson_for_goal ~goal record ])
;;

let reconcile_committed_proof config ~goal_id =
  let effects goal (_, verdict) = match verdict with
    | None -> no_goal_effects | Some verdict -> proof_effects config goal verdict in
  let result = Goal_store.transact_goal ~effects config ~goal_id (fun goal ->
    if goal.phase <> Goal_phase.Verifying then
      Ok (goal, (Reconciliation_not_needed goal.phase, None))
    else
      Result.bind (Goal_verification.get_record_authoritative config ~goal_id) (fun record ->
        let proof = match record with
          | Some { Goal_verification.completion = Goal_verification.Proof_proven verdict; _ }
          | Some { Goal_verification.completion = Goal_verification.Proof_refuted verdict; _ } -> Some verdict
          | _ -> None in
        match proof with
        | None -> Ok (goal, (No_committed_proof, None))
        | Some verdict when not (Goal_store.criterion_equal verdict.criterion (Goal_store.criterion_of_goal goal)) ->
          Ok (goal, (No_committed_proof, None))
        | Some verdict ->
          let action, note = match verdict.outcome with
            | Goal_verification.Proven -> Goal_phase.Record_proof_proven, None
            | Goal_verification.Refuted { reason } -> Goal_phase.Record_proof_refuted, Some reason in
          match Goal_phase.decide_transition ~phase:goal.phase ~action with
          | Error detail -> Error detail
          | Ok (Goal_phase.Already _) -> Error "proof reconciliation did not name a phase transition"
          | Ok (Goal_phase.Move_to phase) ->
            Ok (goal_after_proof goal phase note, (Reconciled phase, Some verdict)))) in
  (* This locked re-read keeps its write_error typed — including a store that
     became unavailable after the verifier scan listed it. The scan records
     only its own list read as [Scan_skipped] (RFC-0444 PR-5); a failure here
     reaches it as an unreconciled goal the Goal rows show. *)
  Result.map (fun (_, (outcome, _)) ->
    ignore (deliver_goal_effects config);
    outcome) result
;;

let parse_goal_evidence_refs args =
  match Json_util.assoc_member_opt "evidence_refs" args with
  | None -> Ok None
  | Some (`List rows) ->
      let rec collect acc = function
        | [] -> Ok (Some (List.rev acc))
        | `String reference :: rest ->
            (match Workspace_verification_store.collaboration_reference reference with
             | Some _ -> collect (reference :: acc) rest
             | None -> Error "evidence_refs accepts explicit board: or fusion: references")
        | _ -> Error "evidence_refs must contain strings" in
      collect [] rows
  | _ -> Error "evidence_refs must be a list"

type goal_refusal = { code : error_code; message : string }

type proof_request_error =
  | Store of Goal_store.write_error
  | Refused of goal_refusal

let refuse code message = { code; message }

(* Every capture error names a source the caller referenced, except storage. *)
let refusal_of_evidence_error (error : Verification_collaboration_evidence.error) =
  let code =
    match error with
    | Verification_collaboration_evidence.Invalid_request _ -> Validation_error
    | Access_denied _ -> Permission_denied
    | Source_unavailable _ -> Not_found
    | Storage_failed _ -> Internal_error
  in
  refuse code (Verification_collaboration_evidence.error_to_string error)
;;

let capture_goal_evidence config = function
  | None -> Ok None
  | Some references ->
      Verification_collaboration_evidence.capture ~config
        ~authority:Verification_collaboration_evidence.Goal_workspace ~references
      |> Result.map Option.some
      |> Result.map_error refusal_of_evidence_error

let mark_proof_pending ?submitted_evidence config ~goal_id goal =
  Goal_verification.mark_proof_pending ?submitted_evidence config ~goal_id
    ~criterion:(Goal_store.criterion_of_goal goal)
  |> Result.map_error (refuse Internal_error)
;;

(* A refusal travels in the transaction's result with the goal unchanged, so
   [Goal_store.transact_goal] writes nothing and the refusal keeps its code
   instead of becoming [Goal_store.Rejected]'s string. *)
let transact_or_refuse ?effects config ~goal_id decide =
  match
    Goal_store.transact_goal ?effects:(Option.map (fun make goal -> function
      | Ok result -> make goal result | Error _ -> no_goal_effects) effects) config ~goal_id (fun goal ->
      match decide goal with
      | Ok (updated, result) -> Ok (updated, Ok result)
      | Error refusal -> Ok (goal, Error refusal))
  with
  | Error error -> Error (Store error)
  | Ok (_, Error refusal) -> Error (Refused refusal)
  | Ok (goal, Ok result) -> Ok (goal, result)
;;

let proof_request_failure ~tool_name ~start_time = function
  | Store (Goal_store.Store_unavailable unavailable) ->
    unavailable_result ~tool_name ~start_time unavailable
  | Store (Goal_store.Goal_not_found _ as error) ->
    error_result_typed ~tool_name ~start_time ~code:Not_found
      (Goal_store.write_error_to_string error)
  | Store (Goal_store.Rejected _ | Goal_store.Persist_failed _ as error) ->
    error_result_typed ~tool_name ~start_time ~code:Internal_error
      (Goal_store.write_error_to_string error)
  | Refused { code; message } -> error_result_typed ~tool_name ~start_time ~code message
;;

let request_current_proof ?evidence_refs config ~goal_id =
  transact_or_refuse config ~goal_id (fun goal ->
    match goal.phase with
    | Goal_phase.Executing | Goal_phase.Verifying ->
      Result.bind (capture_goal_evidence config evidence_refs) (fun submitted_evidence ->
        Result.map (fun record -> { goal with phase = Goal_phase.Verifying }, record)
          (mark_proof_pending ?submitted_evidence config ~goal_id goal))
    | Goal_phase.Awaiting_confirmation | Goal_phase.Completed | Goal_phase.Dropped
    | Goal_phase.Paused _ | Goal_phase.Blocked _ ->
      Error (refuse Precondition_failed "goal is not requesting verification"))
;;

let recover_current_proof config ~goal_id =
  Goal_store.transact_goal config ~goal_id (fun goal ->
    match goal.phase with
    | Goal_phase.Verifying ->
        Result.map (fun _record -> goal, true)
          (Goal_verification.mark_proof_pending config ~goal_id
             ~criterion:(Goal_store.criterion_of_goal goal))
    | Goal_phase.Awaiting_confirmation | Goal_phase.Executing | Goal_phase.Completed | Goal_phase.Dropped
    | Goal_phase.Paused _ | Goal_phase.Blocked _ ->
        Ok (goal, false))
  |> Result.map snd
;;

(* A repeated [request_complete] on [Verifying] is the explicit retry that
   replaces wall-clock expiry (RFC-0387 §5). A missing durable request is
   re-armed, a standing pending request is woken again, and a committed
   verdict whose phase/event write was interrupted is reconciled from that
   exact ledger row without another model call. *)
let answer_verifying_repeat ?evidence_refs ~tool_name ~start_time (ctx : context) ~goal_id ~action _goal =
  let effects goal (_, reconciled) = match reconciled with
    | None -> no_goal_effects
    | Some (verdict, _) -> proof_effects ctx.config goal verdict in
  let result = transact_or_refuse ~effects ctx.config ~goal_id (fun goal ->
    Result.bind
      (Goal_verification.get_record_authoritative ctx.config ~goal_id
       |> Result.map_error (refuse Internal_error))
      (fun record ->
        if goal.phase <> Goal_phase.Verifying then Ok (goal, (record, None))
        else
          match record with
          | Some ({ Goal_verification.completion =
              (Goal_verification.Proof_proven verdict | Goal_verification.Proof_refuted verdict); _ } as record)
            when Goal_verification.relation_for_goal ~goal record = Goal_verification.Current ->
              if Option.is_some evidence_refs then
                Error
                  (refuse Validation_error
                     "proof result is already committed; reconcile it without evidence_refs before submitting new evidence")
              else
              let proof_action, note = match verdict.outcome with
                | Goal_verification.Proven -> Goal_phase.Record_proof_proven, None
                | Goal_verification.Refuted { reason } -> Goal_phase.Record_proof_refuted, Some reason in
              (match Goal_phase.decide_transition ~phase:goal.phase ~action:proof_action with
               | Ok (Goal_phase.Move_to phase) ->
                   Ok (goal_after_proof goal phase note, (Some record, Some (verdict, record)))
               | Ok (Goal_phase.Already _) ->
                   Error (refuse Internal_error "proof reconciliation did not name a transition")
               | Error detail -> Error (refuse Conflict detail))
          | Some _ | None ->
              Result.bind (capture_goal_evidence ctx.config evidence_refs) (fun submitted_evidence ->
                Result.map (fun record -> goal, (Some record, None))
                  (mark_proof_pending ?submitted_evidence ctx.config ~goal_id goal)))) in
  match result with
  | Error error -> proof_request_failure ~tool_name ~start_time error
  | Ok (goal, (record, reconciled)) ->
      let delivery = deliver_goal_effects ctx.config in
      (match goal.phase, record with
       | Goal_phase.Verifying, Some { Goal_verification.completion = Goal_verification.Proof_pending _; _ } ->
           notify_goal_verification_pending ctx ~goal_id
       | _ -> ());
      (match reconciled with
       | None -> already_goal_response ~tool_name ~start_time ~goal_id ~action
           ~phase:goal.phase goal record
       | Some (_, proof_record) ->
           ok_result ~tool_name ~start_time
             [ "goal_id", `String goal_id; "action", `String (Goal_phase.action_to_string action)
             ; "noop", `Bool false; "reconciled", `Bool true; "effect_delivery", delivery
             ; "phase", Goal_phase.to_yojson goal.phase; "goal", Goal_store.goal_to_yojson goal
             ; "verification", Goal_verification.record_to_yojson_for_goal ~goal proof_record ])
;;

(* The work a dropped Goal leaves behind. A Task also linked to a Goal that is
   not dropped still serves that Goal and is left alone. Of the rest, unclaimed
   ones are cancelled once the drop commits; held ones keep running, because
   cancelling would discard their work, and the drop notice names them so their
   holders can finish, release or cancel them. *)
type dropped_goal_work = {
  unclaimed : string list;
  held : (string * string) list;
}

let dropped_goal_work config ~goal_id =
  let ( let* ) = Result.bind in
  let* links = Workspace_goal_index.read_goal_task_links_r config in
  let* goals = match Goal_store.load_source config with
    | Goal_store.Available state -> Ok state.goals
    | Goal_store.Uninitialized -> Ok []
    | Goal_store.Unavailable error -> Error (Goal_store.unavailable_to_string error) in
  let* tasks =
    try Ok (Workspace.get_tasks_raw config) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn) in
  let dropped id =
    String.equal id goal_id
    || List.exists (fun (goal : Goal_store.goal) ->
        String.equal goal.id id && goal.phase = Goal_phase.Dropped) goals in
  let linked = Option.value ~default:[] (List.assoc_opt goal_id links) in
  let orphaned (task : Masc_domain.task) =
    List.mem task.id linked
    && List.for_all (fun (id, task_ids) -> not (List.mem task.id task_ids) || dropped id) links in
  Ok (List.fold_right (fun (task : Masc_domain.task) work ->
      if not (orphaned task) then work
      else match task.task_status with
        | Masc_domain.Todo -> { work with unclaimed = task.id :: work.unclaimed }
        | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _ ->
            (match Masc_domain.task_assignee_of_status task.task_status with
             | Some holder -> { work with held = (task.id, holder) :: work.held }
             | None -> work)
        | Masc_domain.Done _ | Masc_domain.Cancelled _ -> work)
    tasks { unclaimed = []; held = [] })
;;

let dropped_goal_notice ~(goal : Goal_store.goal) held =
  Printf.sprintf
    "[goal_dropped] %s — %s\nThese Tasks are still held and serve no live Goal. Finish, release or cancel them:\n%s"
    goal.id goal.title
    (String.concat "\n" (List.map (fun (task_id, holder) -> Printf.sprintf "- %s (%s)" task_id holder) held))
;;

let cancel_dropped_goal_todos (ctx : context) ~goal_id ~note task_ids =
  let reason = match note with
    | Some note -> Printf.sprintf "Goal %s was dropped: %s" goal_id note
    | None -> Printf.sprintf "Goal %s was dropped." goal_id in
  List.partition_map (fun task_id ->
      match Workspace.transition_task_r ctx.config ~agent_name:ctx.agent_name ~task_id
              ~action:Masc_domain.Cancel ~reason () with
      | Ok _ -> Either.Left task_id
      | Error error -> Either.Right (task_id, Masc_domain.masc_error_to_string error))
    task_ids
;;

let dropped_goal_tasks_json ctx ~goal_id ~note = function
  | Error detail -> `Assoc [ "unread", `String detail ]
  | Ok work ->
      let cancelled, failed = cancel_dropped_goal_todos ctx ~goal_id ~note work.unclaimed in
      `Assoc
        [ "cancelled", `List (List.map (fun id -> `String id) cancelled)
        ; "cancel_failed", `List (List.map (fun (id, error) ->
              `Assoc [ "task_id", `String id; "error", `String error ]) failed)
        ; "held", `List (List.map (fun (id, holder) ->
              `Assoc [ "task_id", `String id; "holder", `String holder ]) work.held) ]
;;

(* The cancellation and its audit intent share the Goal transaction. Decide
   from the locked row, including its current review metadata, rather than
   applying a phase calculated from the earlier tool-level read. Delivery is
   retryable even when a subsequent call finds the Goal already dropped. The
   Tasks the drop leaves behind are read before the transaction, so no task
   store read happens under the Goal lock. *)
let finish_goal_drop ~tool_name ~start_time (ctx : context) ~goal_id ~note =
  let work = dropped_goal_work ctx.config ~goal_id in
  let effects (goal : Goal_store.goal) changed : Goal_store.transition_effects =
    if not changed then no_goal_effects
    else
      { events = [ Goal_store.Phase,
          `Assoc [ "phase", `String (Goal_phase.to_string goal.phase)
                 ; "resume_phase", Goal_phase.resume_phase_to_yojson goal.phase
                 ; "actor", `String ctx.agent_name ] ]
      ; notifications = match work with
          | Ok { held = _ :: _ as held; _ } -> [ ctx.agent_name, dropped_goal_notice ~goal held ]
          | Ok { held = []; _ } | Error _ -> [] }
  in
  match Goal_store.transact_goal ~effects ctx.config ~goal_id (fun goal ->
    match Goal_phase.decide_transition ~phase:goal.phase ~action:Goal_phase.Drop with
    | Error detail -> Error detail
    | Ok (Goal_phase.Already _) -> Ok (goal, false)
    | Ok (Goal_phase.Move_to phase) ->
        let last_review_note, last_review_at = match note with
          | None -> goal.last_review_note, goal.last_review_at
          | Some value -> Some value, Some (Masc_domain.now_iso ()) in
        Ok ({ goal with phase; last_review_note; last_review_at }, true)) with
  | Error (Goal_store.Store_unavailable unavailable) ->
      unavailable_result ~tool_name ~start_time unavailable
  | Error (Goal_store.Goal_not_found _ as error) ->
      error_result_typed ~tool_name ~start_time ~code:Not_found
        (Goal_store.write_error_to_string error)
  | Error (Goal_store.Rejected detail) ->
      error_result_typed ~tool_name ~start_time ~code:Conflict detail
  | Error (Goal_store.Persist_failed _ as error) ->
      error_result_typed ~tool_name ~start_time ~code:Internal_error
        (Goal_store.write_error_to_string error)
  | Ok (goal, changed) ->
      if changed then notify_goal_verification_abandoned ctx ~goal_id;
      let tasks = if changed then [ "tasks", dropped_goal_tasks_json ctx ~goal_id ~note work ] else [] in
      let delivery = deliver_goal_effects ctx.config in
      ok_result ~tool_name ~start_time
        ([ "goal_id", `String goal_id
         ; "action", `String (Goal_phase.action_to_string Goal_phase.Drop)
         ; "noop", `Bool (not changed)
         ; "phase", Goal_phase.to_yojson goal.phase
         ; "goal", Goal_store.goal_to_yojson goal
         ; "effect_delivery", delivery ]
         @ tasks)
;;

let finish_goal_reopen ~tool_name ~start_time (ctx : context) ~note goal =
  let goal_id = goal.Goal_store.id in
  match Goal_verification.reopen_goal ctx.config ~goal_id ~actor:ctx.agent_name ~note with
  | Error msg -> error_result_typed ~tool_name ~start_time ~code:Internal_error msg
  | Ok (goal, outcome, phase_changed) ->
    let verification, proof_reset =
      match outcome with
      | Goal_verification.Proof_unchanged record -> record, false
      | Goal_verification.Proof_reset record -> Some record, true
    in
    if not phase_changed && not proof_reset then
      already_goal_response ~tool_name ~start_time ~goal_id
        ~action:Goal_phase.Reopen ~phase:goal.phase goal verification
    else (
      if phase_changed then notify_goal_verification_abandoned ctx ~goal_id;
      emit_goal_event ctx ~goal_id ~event_type:"goal_phase"
        ~payload:(`Assoc
          [ "phase", Goal_phase.to_yojson goal.phase; "actor", `String ctx.agent_name ]);
      ok_result ~tool_name ~start_time
        ([ "goal_id", `String goal_id
         ; "action", `String (Goal_phase.action_to_string Goal_phase.Reopen)
         ; "goal", Goal_store.goal_to_yojson goal
         ]
         @ match verification with
           | None -> []
           | Some record -> [ "verification", Goal_verification.record_to_yojson_for_goal ~goal record ]))
;;

(* Suspension decisions use the current complete lifecycle under the same
   Goal lock as proof commits and criterion edits. Linked Tasks are untouched. *)
let finish_goal_suspension ~tool_name ~start_time (ctx : context) ~goal_id ~action ~note =
  let effects (goal : Goal_store.goal) changed =
    if not changed then no_goal_effects else
      { Goal_store.events = [ Goal_store.Phase,
          `Assoc [ "phase", `String (Goal_phase.to_string goal.phase)
                 ; "resume_phase", Goal_phase.resume_phase_to_yojson goal.phase
                 ; "actor", `String ctx.agent_name
                 ; "action", `String (Goal_phase.action_to_string action) ] ];
        notifications = [] } in
  match Goal_store.transact_goal ~effects ctx.config ~goal_id (fun goal ->
      match Goal_phase.decide_transition ~phase:goal.phase ~action with
      | Error detail -> Error detail
      | Ok (Goal_phase.Already _) -> Ok (goal, false)
      | Ok (Goal_phase.Move_to phase) ->
          let last_review_note, last_review_at = match note with
            | None -> goal.last_review_note, goal.last_review_at
            | Some text -> Some text, Some (Masc_domain.now_iso ()) in
          Ok ({ goal with phase; last_review_note; last_review_at }, true)) with
  | Error (Goal_store.Store_unavailable unavailable) -> unavailable_result ~tool_name ~start_time unavailable
  | Error error -> error_result_typed ~tool_name ~start_time ~code:Conflict
                     (Goal_store.write_error_to_string error)
  | Ok (goal, changed) ->
      (* An explicit restore re-arms verification even on a repeated delivery.
         The daemon binds again under the Goal lock before admitting work. *)
      (match action, goal.phase with
       | (Goal_phase.Resume | Goal_phase.Unblock), Goal_phase.Verifying ->
           notify_goal_verification_pending ctx ~goal_id
       | _ -> ());
      let delivery = deliver_goal_effects ctx.config in
      ok_result ~tool_name ~start_time
        [ "goal_id", `String goal_id; "action", `String (Goal_phase.action_to_string action)
        ; "noop", `Bool (not changed); "effect_delivery", delivery
        ; "goal", Goal_store.goal_to_yojson goal ]
;;

let handle_goal_transition ~tool_name ~start_time (ctx : context) args
    : Tool_result.result =
  match parse_goal_evidence_refs args with
  | Error detail -> error_result_typed ~tool_name ~start_time ~code:Validation_error detail
  | Ok evidence_refs ->
  match
    ( validate_string_required args "goal_id"
    , parse_optional_transition_action args "action" )
  with
  | Error err, _ | _, Error err ->
    validation_error_result ~tool_name ~start_time [ err ]
  | Ok _, Ok (Some public_action)
      when Option.is_some evidence_refs && public_action <> Goal_phase.Public_action.Request_complete ->
      error_result_typed ~tool_name ~start_time ~code:Validation_error
        "evidence_refs is only accepted for request_complete"
  | Ok goal_id, Ok (Some public_action) ->
    let action = Goal_phase.Public_action.to_action public_action in
    let note = get_string_opt args "note" in
    (match public_action with
     | Goal_phase.Public_action.Pause | Goal_phase.Public_action.Resume
     | Goal_phase.Public_action.Block | Goal_phase.Public_action.Unblock ->
         finish_goal_suspension ~tool_name ~start_time ctx ~goal_id ~action ~note
     | Goal_phase.Public_action.Request_complete | Goal_phase.Public_action.Drop | Goal_phase.Public_action.Reopen ->
    (match Goal_store.find_goal ctx.config ~goal_id with
     | Goal_store.Goal_absent ->
       error_result_typed ~tool_name ~start_time ~code:Not_found "goal not found"
     (* A store this build cannot read is never "goal not found" (RFC-0444
        S5, criterion 4): it answers the typed Unavailable envelope. *)
     | Goal_store.Store_unavailable unavailable ->
       unavailable_result ~tool_name ~start_time unavailable
     | Goal_store.Goal_found goal when Option.is_some evidence_refs &&
         (match goal.Goal_store.phase with
          | Goal_phase.Executing | Goal_phase.Verifying -> false
          | Goal_phase.Awaiting_confirmation | Goal_phase.Completed | Goal_phase.Dropped
    | Goal_phase.Paused _ | Goal_phase.Blocked _ -> true) ->
       (* The phase decides this, not the arguments. *)
       error_result_typed ~tool_name ~start_time ~code:Precondition_failed
         "this Goal has no active proof request that can accept evidence_refs"
     | Goal_store.Goal_found goal ->
       (match Goal_phase.decide_transition ~phase:goal.phase ~action with
        | Error msg ->
          error_result_typed ~tool_name ~start_time ~code:Conflict msg
        (* The goal already occupies the phase this public lifecycle request
           targets. Verifier verdicts cannot enter this branch because they
           are absent from [Goal_phase.Public_action]. *)
        | Ok (Goal_phase.Already phase) ->
          (match public_action with
           | Goal_phase.Public_action.Request_complete ->
             (match phase with
              | Goal_phase.Verifying ->
                answer_verifying_repeat ?evidence_refs
                  ~tool_name ~start_time ctx ~goal_id ~action goal
              | Goal_phase.Awaiting_confirmation
              | Goal_phase.Executing
              | Goal_phase.Completed
              | Goal_phase.Dropped | Goal_phase.Paused _ | Goal_phase.Blocked _ ->
                already_goal_response
                  ~tool_name ~start_time ~goal_id ~action ~phase goal None)
           | Goal_phase.Public_action.Reopen ->
             finish_goal_reopen ~tool_name ~start_time ctx ~note goal
           | Goal_phase.Public_action.Pause | Goal_phase.Public_action.Resume
           | Goal_phase.Public_action.Block | Goal_phase.Public_action.Unblock ->
             finish_goal_suspension ~tool_name ~start_time ctx ~goal_id ~action ~note
           | Goal_phase.Public_action.Drop ->
             finish_goal_drop ~tool_name ~start_time ctx ~goal_id ~note)
        | Ok (Goal_phase.Move_to _) ->
          (match public_action with
           | Goal_phase.Public_action.Request_complete ->
                (* Executing -> Verifying (RFC-0387 §4): persist the proof
                   request BEFORE the phase write — if the ledger write fails
                   the phase does not move, so a crash between the two leaves a
                   request the verifier can still pick up.

                   Nothing is consulted here to decide whether the request is
                   allowed. Asking to be judged is not a claim; the judgement is
                   the verdict, and refusing the request only hides the goal
                   from the thing that would judge it. *)
                   (match request_current_proof ?evidence_refs ctx.config ~goal_id with
                    | Error error -> proof_request_failure ~tool_name ~start_time error
                    | Ok (updated_goal, record) ->
                      emit_goal_event ctx ~goal_id ~event_type:"goal_phase"
                        ~payload:(`Assoc [ "phase", Goal_phase.to_yojson updated_goal.phase
                                          ; "actor", `String ctx.agent_name ]);
                      notify_goal_verification_pending ctx ~goal_id;
                      ok_result ~tool_name ~start_time
                        [ "goal_id", `String goal_id
                        ; "action", `String (Goal_phase.action_to_string action)
                        ; "goal", Goal_store.goal_to_yojson updated_goal
                        ; "verification", Goal_verification.record_to_yojson_for_goal ~goal:updated_goal record ])
           | Goal_phase.Public_action.Reopen ->
                finish_goal_reopen ~tool_name ~start_time ctx ~note goal
           | Goal_phase.Public_action.Pause | Goal_phase.Public_action.Resume
           | Goal_phase.Public_action.Block | Goal_phase.Public_action.Unblock ->
             finish_goal_suspension ~tool_name ~start_time ctx ~goal_id ~action ~note
           | Goal_phase.Public_action.Drop ->
                finish_goal_drop ~tool_name ~start_time ctx ~goal_id ~note))))
  | Ok _, Ok None ->
    validation_error_result
      ~tool_name
      ~start_time
      [ { field = "action"
        ; constraint_violated = Required
        ; message = "action is required"
        ; expected = Some "string"
        ; received = None
        }
      ]
;;

let confirm_completion ?after_confirmation config ~goal_id ~operator_id
    ~request_id ~verification_run_id ~criterion_revision =
  Goal_store.transact_goal config ~goal_id (fun goal ->
    let open Result.Syntax in
    let* record = Goal_verification.get_record_authoritative config ~goal_id in
    let* verdict = match record with
      | Some {Goal_verification.completion =
          (Goal_verification.Proof_proven verdict | Goal_verification.Human_confirmed (verdict, _)); _}
        when Goal_store.criterion_equal verdict.criterion (Goal_store.criterion_of_goal goal)
          && String.equal goal.criterion_revision criterion_revision
          && String.equal verdict.request_id request_id
          && String.equal verdict.verification_run_id verification_run_id -> Ok verdict
      | _ -> Error "confirmation must name the current proven criterion, request and verifier run" in
    let* transition = Goal_phase.decide_transition ~phase:goal.phase ~action:Goal_phase.Confirm_completion in
    let* record = Goal_verification.record_human_confirmation config ~goal_id verdict ~operator_id in
    let* stored_verdict, confirmation = match record.Goal_verification.completion with
      | Goal_verification.Human_confirmed (stored, confirmation) -> Ok (stored, confirmation)
      | _ -> Error "confirmation store did not retain operator authority" in
    let confirming_operator = confirmation.Goal_verification.operator_id in
    let* () = match after_confirmation with
      | Some step -> step goal stored_verdict confirmation
      | None -> Ok () in
    let updated = match transition with
      | Goal_phase.Move_to phase -> goal_after_proof goal phase goal.last_review_note
      | Goal_phase.Already _ -> goal in
    Ok (updated, (record, updated.phase <> goal.phase, confirming_operator)))
  |> Result.map (fun ((goal : Goal_store.goal), (record, changed, confirming_operator)) ->
    if changed then emit_goal_event {config; agent_name = confirming_operator} ~goal_id
      ~event_type:"goal_phase" ~payload:(`Assoc ["phase", Goal_phase.to_yojson goal.phase;
        "authority_kind", `String "human_operator"; "actor", `String confirming_operator;
        "request_id", `String request_id; "verification_run_id", `String verification_run_id;
        "criterion_revision", `String criterion_revision]);
    `Assoc ["goal", Goal_store.goal_to_yojson goal;
      "verification", Goal_verification.record_to_yojson_for_goal ~goal record])
