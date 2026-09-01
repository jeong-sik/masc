(** Workspace_goals - Handlers for goal management tools. *)

open Workspace_types
open Tool_args

(* Local helpers: build typed [Tool_result.result] from response helpers.
   ~tool_name and ~start_time are threaded through from dispatch.

   RFC-0189 PR-1b.8: handlers return [Tool_result.result]. Failure class is
   [Workflow_rejection] for every error path: all call sites here surface
   caller-input rejections (typed codes [Validation_error] / [Not_found] /
   [Conflict], or [validation_error_response] from [Tool_args]) — none
   originate from internal-state failures. The plain [error_result] helper
   was dead (0 callers) and removed. *)
let ok_result ~tool_name ~start_time fields : Tool_result.result =
  Tool_result.make_ok ~tool_name ~start_time ~data:(ok_assoc fields) ()
;;

let error_result_typed ~tool_name ~start_time ~code msg : Tool_result.result =
  let data =
    error_assoc
      [ "error_code", `String (error_code_to_string code)
      ; "message", `String msg
      ]
  in
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    ~data
    (Yojson.Safe.to_string data)
;;

let validation_error_result
      ~tool_name
      ~start_time
      (errors : field_error list)
  : Tool_result.result
  =
  let data = validation_error_assoc errors in
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    ~data
    (Yojson.Safe.to_string data)
;;

(* RFC-0089: derive the accepted-value sets from the Goal_phase ADT (the goal
   lifecycle SSOT) instead of hand-rolling them here, so the validator, the MCP
   schema enum, and the type can never drift apart. *)
let goal_phase_strings = List.map Goal_phase.to_string Goal_phase.all

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
    (match Goal_store.parse_goal_phase (Some raw) with
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

(* A phase write is decided against the phase the caller read with
   [Goal_store.get_goal] — outside the store lock. Writing that decision with
   a plain overwrite lets a second concurrent transition (also decided on the
   same earlier phase) land a state the FSM never validated, e.g. Dropped on
   top of Verifying. The compare-and-update closes that window: when the
   phase moved in between, the write refuses and the caller reports a
   Conflict instead of inventing a transition. *)
type phase_write_error =
  | Store_error of string
  | Concurrent_transition of { expected : Goal_phase.t; actual : Goal_phase.t }

let update_goal_phase (ctx : context) (goal : Goal_store.goal) ~phase ?note () :
    (Goal_store.goal, phase_write_error) result =
  let last_review_note, last_review_at =
    match note with
    | Some note -> Some note, Some (Masc_domain.now_iso ())
    | None -> goal.last_review_note, goal.last_review_at
  in
  match
    Goal_store.update_goal_if_phase ctx.config ~goal_id:goal.id
      ~expected_phase:goal.phase
      (fun current ->
        { current with
          phase
        ; last_review_note
        ; last_review_at
        })
  with
  | Ok (Goal_store.Goal_updated updated) -> Ok updated
  | Ok (Goal_store.Goal_phase_mismatch actual) ->
    Error (Concurrent_transition { expected = goal.phase; actual })
  | Error msg -> Error (Store_error msg)
;;

let phase_write_error_result ~tool_name ~start_time (error : phase_write_error) =
  match error with
  | Store_error msg ->
    error_result_typed ~tool_name ~start_time ~code:Internal_error msg
  | Concurrent_transition { expected; actual } ->
    error_result_typed ~tool_name ~start_time ~code:Conflict
      (Printf.sprintf
         "goal phase moved from %s to %s while this transition was being \
          decided; re-read the goal and retry"
         (Goal_phase.to_string expected) (Goal_phase.to_string actual))
;;

let emit_goal_event (ctx : context) ~goal_id ~event_type ~payload =
  let path =
    Filename.concat (Workspace_utils.masc_dir ctx.config) "goal_events.jsonl"
  in
  Fs_compat.append_jsonl
    path
    (`Assoc
       [ "ts", `String (Masc_domain.now_iso ())
       ; "goal_id", `String goal_id
       ; "event_type", `String event_type
       ; "payload", payload
       ])
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

let handle_goal_list ~tool_name ~start_time (ctx : context) args : Tool_result.result =
  match
    ( reject_retired_goal_list_status args
    , parse_optional_goal_phase args "phase" )
  with
  | Error err, _ | _, Error err ->
    validation_error_result ~tool_name ~start_time [ err ]
  | Ok (), Ok phase ->
    let goals = Goal_store.list_goals ctx.config ?phase () in
    let rollup = Goal_store.compute_rollup goals in
    (* RFC-0387 (stage 1): the verification ledger joins each goal here (not
       in [Goal_store.goal_to_yojson], which is the persistence codec). The
       ledger is loaded ONCE per request and joined in memory; a store that
       does not decode renders the explicit [ledger_error] marker per goal —
       never the pre-verification default, which would disguise corruption as
       "not verified yet". *)
    let records = Goal_verification.load_records ctx.config in
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
          |> Goal_verification.record_to_yojson
      in
      match Goal_store.goal_to_yojson goal with
      | `Assoc fields -> `Assoc (fields @ [ "verification", verification ])
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
          Goal_store.upsert_goal
            ctx.config
            ?id
            ?title
            ?metric
            ?target_value
            ?due_date
            ?priority
            ()
        with
        | Error msg ->
          error_result_typed ~tool_name ~start_time ~code:Validation_error msg
        | Ok (goal, action) ->
          let action_name =
            match action with
            | `created -> "created"
            | `updated -> "updated"
          in
          ok_result
            ~tool_name
            ~start_time
            [ "action", `String action_name
            ; "goal_id", `String goal.id
            ; "goal", Goal_store.goal_to_yojson goal
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
  | Goal_phase.Request_complete
  | Goal_phase.Drop
  | Goal_phase.Reopen -> false
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
   name. [Runtime.verifier_exact_lane_id] is the runtime configuration SSOT. *)
let gate_verdict
      (outcome : Goal_verification.verdict_outcome)
      ~verification_run_id
      ~evidence
    : Goal_verification.verdict
  =
  { Goal_verification.outcome
  ; verification_run_id
  ; authority =
      Masc_domain.System_llm_agent
        { agent_run_id = Runtime.verifier_exact_lane_id }
  ; evidence
  ; recorded_at = Masc_domain.now_iso ()
  }
;;

(* A Keeper requests completion and the verifier answers out of band. Without
   this the answer lands in the ledger and nowhere else: no module under
   lib/keeper reads [Goal_verification], so a Keeper learns its own proof was
   judged only by calling masc_goal_list and looking. The record stays the
   authority; this is the projection that reaches the conversation.

   A failed announcement does not undo the verdict — the ledger row is already
   committed and readable — so it warns rather than failing the commit. *)
let announce_proof_verdict
      (ctx : context)
      ~(goal : Goal_store.goal)
      (verdict : Goal_verification.verdict)
  =
  let outcome_line =
    match verdict.outcome with
    | Goal_verification.Proven -> "proven"
    | Goal_verification.Refuted { reason } -> "refuted: " ^ reason
  in
  let content =
    Printf.sprintf
      "[goal_verdict] %s — %s\noutcome: %s\nevidence: %s"
      goal.Goal_store.id
      goal.Goal_store.title
      outcome_line
      verdict.evidence
  in
  match
    Workspace_broadcast.broadcast
      ~audience:Workspace_broadcast.Fleet_conversation
      ctx.config
      ~from_agent:ctx.agent_name
      ~content
  with
  | Ok _ -> ()
  | Error error ->
    Log.Misc.warn
      "goal verdict announcement failed goal_id=%s: %s"
      goal.Goal_store.id
      (Workspace_broadcast.broadcast_error_to_string error)
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
     ; "evidence", `String verdict.evidence
     ]
     @ outcome_fields)
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
       [ "verification", Goal_verification.record_to_yojson record ]
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

let commit_verifier_decision
      ~tool_name
      ~start_time
      config
      ~goal_id
      ~verification_run_id
      ~decision
      ~evidence
  =
  let ctx : context =
    { config; agent_name = Runtime.verifier_exact_lane_id }
  in
  let action, verdict_outcome, note = verifier_decision_parts decision in
  match
    ( validate_verification_run_id verification_run_id
    , validate_gate_evidence (`Assoc [ "evidence", `String evidence ]) action )
  with
  | Error errors, _ | _, Error errors ->
    validation_error_result ~tool_name ~start_time errors
  | Ok verification_run_id, Ok evidence ->
    (match Goal_store.get_goal config ~goal_id with
     | None ->
       error_result_typed ~tool_name ~start_time ~code:Not_found "goal not found"
     | Some goal ->
       (match Goal_phase.decide_transition ~phase:goal.phase ~action with
        | Error msg ->
          error_result_typed ~tool_name ~start_time ~code:Conflict msg
        | Ok (Goal_phase.Already _) ->
          error_result_typed
            ~tool_name
            ~start_time
            ~code:Conflict
            "proof verdict did not name a phase transition"
        | Ok (Goal_phase.Move_to phase) ->
          (match decision with
           | Proof_proven | Proof_refuted _ ->
             let verdict =
               gate_verdict verdict_outcome ~verification_run_id ~evidence
             in
             (match Goal_verification.record_proof_verdict config ~goal_id verdict with
              | Error msg ->
                error_result_typed ~tool_name ~start_time ~code:Conflict msg
              | Ok record ->
                (match update_goal_phase ctx goal ~phase ?note () with
                 | Error error ->
                   phase_write_error_result ~tool_name ~start_time error
                 | Ok updated_goal ->
                   emit_goal_event
                     ctx
                     ~goal_id
                     ~event_type:"goal_phase"
                     ~payload:(gate_event_payload ctx ~phase verdict);
                   announce_proof_verdict ctx ~goal:updated_goal verdict;
                   ok_result
                     ~tool_name
                     ~start_time
                     [ "goal_id", `String goal_id
                     ; "action", `String (Goal_phase.action_to_string action)
                     ; "goal", Goal_store.goal_to_yojson updated_goal
                     ; "verification", Goal_verification.record_to_yojson record
                     ])))))
;;

let reconcile_committed_proof config ~goal_id =
  let ctx : context =
    { config; agent_name = Runtime.verifier_exact_lane_id }
  in
  match Goal_store.get_goal config ~goal_id with
  | None -> Error (Printf.sprintf "goal not found: %s" goal_id)
  | Some goal when goal.phase <> Goal_phase.Verifying ->
    Ok (Reconciliation_not_needed goal.phase)
  | Some goal ->
    (match Goal_verification.get_record config ~goal_id with
     | Error _ as error -> error
     | Ok None -> Ok No_committed_proof
     | Ok
         (Some
           { Goal_verification.completion =
               Goal_verification.Proof_proven
                 { outcome = Goal_verification.Refuted _; _ }
           ; _
           }) ->
       Error "proof_proven ledger state carries a refuted verdict"
     | Ok
         (Some
           { Goal_verification.completion =
               Goal_verification.Proof_refuted
                 { outcome = Goal_verification.Proven; _ }
           ; _
           }) ->
       Error "proof_refuted ledger state carries a proven verdict"
     | Ok (Some record) ->
       let transition =
         match record.completion with
         | Goal_verification.Proof_proven verdict ->
           Some (Goal_phase.Record_proof_proven, verdict, None)
         | Goal_verification.Proof_refuted
             ({ outcome = Goal_verification.Refuted { reason }; _ } as verdict) ->
           Some (Goal_phase.Record_proof_refuted, verdict, Some reason)
         | Goal_verification.Proof_refuted
             { outcome = Goal_verification.Proven; _ } ->
           (* Rejected by the explicit malformed-ledger guard above. This arm
              keeps the closed sum exhaustive at the use site. *)
           None
         | Goal_verification.Completion_idle
         | Goal_verification.Proof_pending _ -> None
       in
       match transition with
       | None -> Ok No_committed_proof
       | Some (action, verdict, note) ->
         (match Goal_phase.decide_transition ~phase:goal.phase ~action with
          | Error msg -> Error msg
          | Ok (Goal_phase.Already _) ->
            Error "committed proof reconciliation did not name a phase transition"
          | Ok (Goal_phase.Move_to phase) ->
            let update (current : Goal_store.goal) =
              let last_review_note, last_review_at =
                match note with
                | Some note -> Some note, Some (Masc_domain.now_iso ())
                | None -> current.last_review_note, current.last_review_at
              in
              { current with phase; last_review_note; last_review_at }
            in
            (match
               Goal_store.update_goal_if_phase
                 config
                 ~goal_id
                 ~expected_phase:Goal_phase.Verifying
                 update
             with
             | Error _ as error -> error
             | Ok (Goal_store.Goal_phase_mismatch current_phase) ->
               Ok (Reconciliation_not_needed current_phase)
             | Ok (Goal_store.Goal_updated _) ->
               emit_goal_event
                 ctx
                 ~goal_id
                 ~event_type:"goal_phase"
                 ~payload:(gate_event_payload ctx ~phase verdict);
               Ok (Reconciled phase))))
;;

(* A repeated [request_complete] on [Verifying] is the explicit retry that
   replaces wall-clock expiry (RFC-0387 §5). A missing durable request is
   re-armed, a standing pending request is woken again, and a committed
   verdict whose phase/event write was interrupted is reconciled from that
   exact ledger row without another model call. *)
let answer_verifying_repeat ~tool_name ~start_time (ctx : context) ~goal_id ~action goal =
  match Goal_verification.get_record ctx.config ~goal_id with
  | Error msg -> error_result_typed ~tool_name ~start_time ~code:Internal_error msg
  | Ok record ->
    (match record with
     | Some
         ({ Goal_verification.completion = Goal_verification.Proof_pending _; _ }
          as pending_record) ->
       notify_goal_verification_pending ctx ~goal_id;
       already_goal_response
         ~tool_name ~start_time ~goal_id ~action ~phase:Goal_phase.Verifying goal
         (Some pending_record)
     | Some
         ({ Goal_verification.completion =
              (Goal_verification.Proof_proven _ | Goal_verification.Proof_refuted _)
          ; _
          } as committed_record) ->
       (match reconcile_committed_proof ctx.config ~goal_id with
        | Error msg ->
          error_result_typed ~tool_name ~start_time ~code:Internal_error msg
        | Ok No_committed_proof ->
          error_result_typed
            ~tool_name
            ~start_time
            ~code:Internal_error
            "committed proof disappeared during phase reconciliation"
        | Ok (Reconciliation_not_needed phase) ->
          (match Goal_store.get_goal ctx.config ~goal_id with
           | None ->
             error_result_typed
               ~tool_name ~start_time ~code:Internal_error "goal disappeared"
           | Some current_goal ->
             already_goal_response
               ~tool_name
               ~start_time
               ~goal_id
               ~action
               ~phase
               current_goal
               (Some committed_record))
        | Ok (Reconciled phase) ->
          (match Goal_store.get_goal ctx.config ~goal_id with
           | None ->
             error_result_typed
               ~tool_name ~start_time ~code:Internal_error "goal disappeared"
           | Some updated_goal ->
             ok_result
               ~tool_name
               ~start_time
               [ "goal_id", `String goal_id
               ; "action", `String (Goal_phase.action_to_string action)
               ; "noop", `Bool false
               ; "reconciled", `Bool true
               ; "phase", Goal_phase.to_yojson phase
               ; "goal", Goal_store.goal_to_yojson updated_goal
               ; ( "verification"
                 , Goal_verification.record_to_yojson committed_record )
               ]))
     | Some { Goal_verification.completion = Goal_verification.Completion_idle; _ }
     | None ->
       (match Goal_verification.mark_proof_pending ctx.config ~goal_id with
        | Error msg ->
          error_result_typed ~tool_name ~start_time ~code:Internal_error msg
        | Ok record ->
          notify_goal_verification_pending ctx ~goal_id;
          already_goal_response
            ~tool_name ~start_time ~goal_id ~action ~phase:Goal_phase.Verifying goal
            (Some record)))
;;

let handle_goal_transition ~tool_name ~start_time (ctx : context) args
    : Tool_result.result =
  match
    ( validate_string_required args "goal_id"
    , parse_optional_transition_action args "action" )
  with
  | Error err, _ | _, Error err ->
    validation_error_result ~tool_name ~start_time [ err ]
  | Ok goal_id, Ok (Some public_action) ->
    let action = Goal_phase.Public_action.to_action public_action in
    let note = get_string_opt args "note" in
    (match Goal_store.get_goal ctx.config ~goal_id with
     | None ->
       error_result_typed ~tool_name ~start_time ~code:Not_found "goal not found"
     | Some goal ->
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
                answer_verifying_repeat
                  ~tool_name ~start_time ctx ~goal_id ~action goal
              | Goal_phase.Executing
              | Goal_phase.Completed
              | Goal_phase.Dropped ->
                already_goal_response
                  ~tool_name ~start_time ~goal_id ~action ~phase goal None)
           | Goal_phase.Public_action.Drop
           | Goal_phase.Public_action.Reopen ->
             already_goal_response
               ~tool_name ~start_time ~goal_id ~action ~phase goal None)
        | Ok (Goal_phase.Move_to phase) ->
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
                   (match
                      Goal_verification.mark_proof_pending ctx.config ~goal_id
                    with
                    | Error msg ->
                      error_result_typed
                        ~tool_name ~start_time ~code:Internal_error msg
                    | Ok record ->
                      (match update_goal_phase ctx goal ~phase ?note () with
                       | Error error ->
                         phase_write_error_result ~tool_name ~start_time error
                       | Ok updated_goal ->
                         emit_goal_event
                           ctx
                           ~goal_id
                           ~event_type:"goal_phase"
                           ~payload:
                             (`Assoc
                                [ "phase", Goal_phase.to_yojson updated_goal.phase
                                ; "actor", `String ctx.agent_name
                                ]);
                         (* The durable proof request AND the phase write both
                            committed — wake the verifier lane to drain it
                            (the task-side analogue fires after the same two
                            commits). *)
                         notify_goal_verification_pending ctx ~goal_id;
                         ok_result
                           ~tool_name
                           ~start_time
                           [ "goal_id", `String goal_id
                           ; "action", `String (Goal_phase.action_to_string action)
                           ; "goal", Goal_store.goal_to_yojson updated_goal
                           ; ( "verification"
                             , Goal_verification.record_to_yojson record )
                           ]))
           | Goal_phase.Public_action.Drop
           | Goal_phase.Public_action.Reopen ->
                (match update_goal_phase ctx goal ~phase ?note () with
                 | Error error ->
                   phase_write_error_result ~tool_name ~start_time error
                 | Ok updated_goal ->
                   emit_goal_event
                     ctx
                     ~goal_id
                     ~event_type:"goal_phase"
                     ~payload:
                       (`Assoc
                          [ "phase", Goal_phase.to_yojson updated_goal.phase
                          ; "actor", `String ctx.agent_name
                          ]);
                   ok_result
                     ~tool_name
                     ~start_time
                     [ "goal_id", `String goal_id
                     ; "action", `String (Goal_phase.action_to_string action)
                     ; "goal", Goal_store.goal_to_yojson updated_goal
                     ]))))
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
