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
   [Goal_store.find_goal] — outside the store lock. Writing that decision with
   a plain overwrite lets a second concurrent transition (also decided on the
   same earlier phase) land a state the FSM never validated, e.g. Dropped on
   top of Verifying. The compare-and-update closes that window: when the
   phase moved in between, the write refuses and the caller reports a
   Conflict instead of inventing a transition. *)
type phase_write_error =
  | Store_unavailable of Goal_store.unavailable
  | Goal_missing of string
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
  | Error (Goal_store.Store_unavailable unavailable) -> Error (Store_unavailable unavailable)
  | Error (Goal_store.Goal_not_found _ as error) ->
    Error (Goal_missing (Goal_store.write_error_to_string error))
  | Error (Goal_store.Rejected _ | Goal_store.Persist_failed _ as error) ->
    Error (Store_error (Goal_store.write_error_to_string error))
;;

let phase_write_error_result ~tool_name ~start_time (error : phase_write_error) =
  match error with
  | Store_unavailable unavailable -> unavailable_result ~tool_name ~start_time unavailable
  | Goal_missing msg -> error_result_typed ~tool_name ~start_time ~code:Not_found msg
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
    match Goal_store.list_goals_result ctx.config ?phase () with
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
          Goal_store.upsert_goal
            ctx.config
            ?id
            ?title
            ?metric
            ?target_value
            ?due_date
            ?priority
            ~owner:ctx.agent_name
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
        | Ok (goal, action) ->
          let action_name =
            match action with
            | `created -> "created"
            | `updated _ -> "updated"
          in
          (* A goal's creation emitted nothing, so goals.json -- which holds only
             the current set -- was the only record that one ever existed. A goal
             that finished and left the set left nothing behind to count or to
             name, which is why "how many goals were opened" and "what were they"
             had no answer (#35359). Phase transitions already emit; this closes
             the other end of the same ledger. The payload is the goal as created
             so its title outlives its row in the store. An update is not a second
             beginning and emits no goal_created; only an update that moves the
             phase records a goal_phase event. *)
          (match action with
           | `created ->
             emit_goal_event ctx ~goal_id:goal.id ~event_type:"goal_created"
               ~payload:(Goal_store.goal_to_yojson goal)
           | `updated previous_phase ->
             (* An edit to the success criterion takes a Verifying,
                Awaiting_confirmation or Completed goal back to Executing
                (Goal_store.upsert_goal). That is a phase move like any
                other, so it enters the same ledger with the phase it left and
                who moved it. *)
             if previous_phase <> goal.phase then
               emit_goal_event ctx ~goal_id:goal.id ~event_type:"goal_phase"
                 ~payload:
                   (`Assoc
                      [ "phase", Goal_phase.to_yojson goal.phase
                      ; "previous_phase", Goal_phase.to_yojson previous_phase
                      ; "actor", `String ctx.agent_name
                      ; "cause", `String "criterion_edit"
                      ]));
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

(* {1 Owner-directed Goal notices (#39571)}

   A Goal records the Keeper that created it. Two events are worth one direct
   notice to that owner: a refuted proof verdict, and a due date that passed
   while the Goal is still executing or verifying. The notice is a Pending
   Message in the owner's own transcript, not a fleet broadcast: the owner is
   the one who must act, and a broadcast would put the same line in every
   Keeper's window.

   A Goal with no recorded owner has no recipient. The notice is skipped and
   the screen keeps showing "unknown" so the operator can set an owner
   explicitly; nothing is posted to the Board on the owner's behalf.

   Delivery is idempotent by the [Goal_notification] key (goal id, owner, and
   the one event). The same event, a retry after a failed send, or a restart
   all reuse the key, so the owner's transcript gains exactly one row. The
   Goal's marker is written only after the row is durably committed, so a
   crash between the two re-sends and the append-once path keeps the count at
   one. *)

type goal_notice_kind =
  | Refuted_notice
  | Overdue_notice

let goal_notice_key ~goal_id ~owner ~event = goal_id ^ "|" ^ owner ^ "|" ^ event

let goal_notice_speaker : Keeper_chat_store.speaker =
  { speaker_id = Some "goal-verifier"
  ; speaker_name = Some "goal-verifier"
  ; speaker_authority = Keeper_chat_store.External
  }
;;

let deliver_goal_owner_notice config ~(goal : Goal_store.goal) ~event ~content =
  match goal.Goal_store.owner with
  | Goal_store.Unknown_owner -> Ok ()
  | Goal_store.Owner owner ->
    let delivery_key =
      Keeper_chat_delivery_identity.Goal_notification
        { goal_id = goal.Goal_store.id; owner; event }
    in
    let mentions =
      match Keeper_identity.Keeper_id.of_string owner with
      | Some keeper_id -> [ keeper_id ]
      | None -> []
    in
    (match
       Keeper_chat_store.append_user_message_once
         ~base_dir:config.Workspace_utils_backend_setup.base_path
         ~keeper_name:owner
         ~delivery_key
         ~content
         ~surface:Surface_ref.Agent
         ~speaker:goal_notice_speaker
         ~extra_mentions:mentions
         ()
     with
     | Ok _ -> Ok ()
     | Error detail -> Error detail)
;;

let mark_goal_notice config ~goal_id kind ~key =
  let apply (goal : Goal_store.goal) =
    match kind with
    | Refuted_notice -> { goal with Goal_store.notified_refuted_key = Some key }
    | Overdue_notice -> { goal with Goal_store.notified_overdue_key = Some key }
  in
  match Goal_store.transact_goal config ~goal_id (fun goal -> Ok (apply goal, ())) with
  | Ok _ -> ()
  | Error error ->
    Log.Misc.warn
      "goal notice marker write failed goal_id=%s: %s"
      goal_id
      (Goal_store.write_error_to_string error)
;;

let refuted_notice_event (verdict : Goal_verification.verdict) =
  "refuted:" ^ verdict.Goal_verification.request_id
;;

let refuted_notice_content ~(goal : Goal_store.goal)
    (verdict : Goal_verification.verdict) =
  Printf.sprintf
    "[goal_verdict] %s — %s\noutcome: refuted\nevidence: %s"
    goal.Goal_store.id
    goal.Goal_store.title
    verdict.Goal_verification.evidence
;;

(* Deliver the one refuted notice owed for [verdict] to [owner], then record the
   marker. The marker is written only after the row is durably committed, so a
   failed send leaves the debt outstanding for the next scan to retry. *)
let deliver_refuted_notice config ~(goal : Goal_store.goal) ~owner
    (verdict : Goal_verification.verdict) =
  let event = refuted_notice_event verdict in
  let key = goal_notice_key ~goal_id:goal.Goal_store.id ~owner ~event in
  match
    deliver_goal_owner_notice config ~goal ~event
      ~content:(refuted_notice_content ~goal verdict)
  with
  | Ok () -> mark_goal_notice config ~goal_id:goal.Goal_store.id Refuted_notice ~key
  | Error detail ->
    Log.Misc.warn
      "goal refuted owner notice failed goal_id=%s owner=%s: %s"
      goal.Goal_store.id
      owner
      detail
;;

let notify_goal_refuted config ~(goal : Goal_store.goal)
    (verdict : Goal_verification.verdict) =
  match goal.Goal_store.owner with
  | Goal_store.Unknown_owner -> ()
  | Goal_store.Owner owner -> deliver_refuted_notice config ~goal ~owner verdict
;;

(* [due_date] is a calendar date with no zone, so it is compared with the
   operator's own calendar date — the day [localtime] puts [now] on — matching
   the Overview's own overdue rule. Anything that is not a calendar date is not
   overdue. *)
let goal_due_date_passed ~today (goal : Goal_store.goal) =
  match goal.Goal_store.due_date with
  | None -> false
  | Some raw ->
    (match
       Scanf.sscanf_opt (String.trim raw) "%4d-%2d-%2d%!" (fun y m d -> (y, m, d))
     with
     | None -> false
     | Some date ->
       (match Ptime.of_date date with
        | None -> false
        | Some due -> Ptime.compare due today < 0))
;;

let local_today () =
  let tm = Unix.localtime (Time_compat.now ()) in
  Ptime.of_date (tm.Unix.tm_year + 1900, tm.Unix.tm_mon + 1, tm.Unix.tm_mday)
;;

(* The overdue notice is judged by the server's periodic/restart scan, never as
   a side effect of a list query: a read must not send. The scan is idempotent
   — the marker skips an already-notified Goal, and the delivery key makes a
   re-send a no-op — so it is safe to run on every maintenance tick. *)
let scan_overdue_goal_notifications config =
  match Goal_store.list_goals_result config () with
  | Error _ -> ()
  | Ok goals ->
    (match local_today () with
     | None -> ()
     | Some today ->
    List.iter
      (fun (goal : Goal_store.goal) ->
         match goal.Goal_store.owner, goal.Goal_store.phase with
         | Goal_store.Unknown_owner, _ -> ()
         | Goal_store.Owner owner, (Goal_phase.Executing | Goal_phase.Verifying) ->
           (match goal.Goal_store.due_date with
            | Some due_date when goal_due_date_passed ~today goal ->
              let event = "overdue:" ^ due_date in
              let key = goal_notice_key ~goal_id:goal.Goal_store.id ~owner ~event in
              if goal.Goal_store.notified_overdue_key = Some key
              then ()
              else (
                let content =
                  Printf.sprintf
                    "[goal_overdue] %s — %s\ndue_date: %s\nphase: %s"
                    goal.Goal_store.id
                    goal.Goal_store.title
                    due_date
                    (Goal_phase.to_string goal.Goal_store.phase)
                in
                match deliver_goal_owner_notice config ~goal ~event ~content with
                | Ok () ->
                  mark_goal_notice config ~goal_id:goal.Goal_store.id Overdue_notice ~key
                | Error detail ->
                  Log.Misc.warn
                    "goal overdue owner notice failed goal_id=%s owner=%s: %s"
                    goal.Goal_store.id
                    owner
                    detail)
            | _ -> ())
         | Goal_store.Owner _, _ -> ())
      goals)
;;

(* A refuted verdict is delivered at commit time, but a failed send must not be
   the owner's last chance to hear it. The same periodic/restart scan reconciles
   the ledger's current refuted verdict against the Goal's marker: a send that
   failed (no marker) is retried, and a Goal whose owner changed after the
   verdict reaches the new owner because the key carries the owner. A verdict
   whose criterion no longer matches the Goal is stale and is not re-sent. *)
let scan_refuted_goal_notifications config =
  match Goal_store.list_goals_result config () with
  | Error _ -> ()
  | Ok goals ->
    (match Goal_verification.load_records_authoritative config with
     | Error detail ->
       Log.Misc.warn
         "goal refuted owner notice scan skipped: verification ledger unreadable: %s"
         detail
     | Ok records ->
       List.iter
         (fun (goal : Goal_store.goal) ->
            match goal.Goal_store.owner with
            | Goal_store.Unknown_owner -> ()
            | Goal_store.Owner owner ->
              (match
                 List.find_opt
                   (fun (record : Goal_verification.record) ->
                      String.equal record.Goal_verification.goal_id goal.Goal_store.id)
                   records
               with
               | Some ({ Goal_verification.completion =
                           Goal_verification.Proof_refuted verdict; _ } as record)
                 when Goal_verification.relation_for_goal ~goal record
                      = Goal_verification.Current ->
                 let event = refuted_notice_event verdict in
                 let key = goal_notice_key ~goal_id:goal.Goal_store.id ~owner ~event in
                 if goal.Goal_store.notified_refuted_key = Some key
                 then ()
                 else deliver_refuted_notice config ~goal ~owner verdict
               | Some _ | None -> ()))
         goals)
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

let commit_verifier_decision ~tool_name ~start_time config ~goal_id
    ~verification_run_id ~request_id ~criterion ~decision ~evidence =
  let ctx : context = { config; agent_name = Standalone_lane.to_id Standalone_lane.Verifier } in
  let action, verdict_outcome, note = verifier_decision_parts decision in
  match validate_verification_run_id verification_run_id,
        validate_gate_evidence (`Assoc [ "evidence", `String evidence ]) action with
  | Error errors, _ | _, Error errors -> validation_error_result ~tool_name ~start_time errors
  | Ok verification_run_id, Ok evidence ->
    let verdict = gate_verdict verdict_outcome ~verification_run_id ~request_id ~criterion ~evidence in
    let committed = Goal_store.transact_goal config ~goal_id (fun goal ->
      if not (Goal_store.criterion_equal criterion (Goal_store.criterion_of_goal goal)) then
        Error "proof criterion has been superseded"
      else
        match Goal_phase.decide_transition ~phase:goal.phase ~action with
        | Ok (Goal_phase.Move_to phase) ->
          Result.map (fun record -> goal_after_proof goal phase note, (record, true))
            (Goal_verification.record_proof_verdict config ~goal_id verdict)
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
                      | _ -> false) -> Ok (goal, (record, false))
              | _ -> Error detail)
        | Ok (Goal_phase.Already _) -> Error "proof verdict did not name a phase transition") in
    (match committed with
     | Error (Goal_store.Store_unavailable unavailable) ->
       unavailable_result ~tool_name ~start_time unavailable
     | Error (Goal_store.Goal_not_found _ | Goal_store.Rejected _
             | Goal_store.Persist_failed _ as error) ->
       error_result_typed ~tool_name ~start_time ~code:Conflict
         (Goal_store.write_error_to_string error)
     | Ok (goal, (record, changed)) ->
       if changed then (
         emit_goal_event ctx ~goal_id ~event_type:"goal_phase"
           ~payload:(gate_event_payload ctx ~phase:goal.phase verdict);
         announce_proof_verdict ctx ~goal verdict;
         (match verdict.outcome with
          | Goal_verification.Refuted _ -> notify_goal_refuted config ~goal verdict
          | Goal_verification.Proven -> ()));
       ok_result ~tool_name ~start_time
         [ "goal_id", `String goal_id
         ; "action", `String (Goal_phase.action_to_string action)
         ; "noop", `Bool (not changed)
         ; "goal", Goal_store.goal_to_yojson goal
         ; "verification", Goal_verification.record_to_yojson_for_goal ~goal record ])
;;

let reconcile_committed_proof config ~goal_id =
  let ctx : context = { config; agent_name = Standalone_lane.to_id Standalone_lane.Verifier } in
  let result = Goal_store.transact_goal config ~goal_id (fun goal ->
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
  Result.map (fun ((goal : Goal_store.goal), (outcome, verdict)) ->
    Option.iter (fun verdict -> emit_goal_event ctx ~goal_id ~event_type:"goal_phase"
      ~payload:(gate_event_payload ctx ~phase:goal.phase verdict)) verdict;
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
let transact_or_refuse config ~goal_id decide =
  match
    Goal_store.transact_goal config ~goal_id (fun goal ->
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
    | Goal_phase.Awaiting_confirmation | Goal_phase.Completed | Goal_phase.Dropped ->
      Error (refuse Precondition_failed "goal is not requesting verification"))
;;

let recover_current_proof config ~goal_id =
  Goal_store.transact_goal config ~goal_id (fun goal ->
    match goal.phase with
    | Goal_phase.Verifying ->
        Result.map (fun _record -> goal, true)
          (Goal_verification.mark_proof_pending config ~goal_id
             ~criterion:(Goal_store.criterion_of_goal goal))
    | Goal_phase.Awaiting_confirmation | Goal_phase.Executing | Goal_phase.Completed | Goal_phase.Dropped ->
        Ok (goal, false))
  |> Result.map snd
;;

(* A repeated [request_complete] on [Verifying] is the explicit retry that
   replaces wall-clock expiry (RFC-0387 §5). A missing durable request is
   re-armed, a standing pending request is woken again, and a committed
   verdict whose phase/event write was interrupted is reconciled from that
   exact ledger row without another model call. *)
let answer_verifying_repeat ?evidence_refs ~tool_name ~start_time (ctx : context) ~goal_id ~action _goal =
  let result = transact_or_refuse ctx.config ~goal_id (fun goal ->
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
      (match goal.phase, record with
       | Goal_phase.Verifying, Some { Goal_verification.completion = Goal_verification.Proof_pending _; _ } ->
           notify_goal_verification_pending ctx ~goal_id
       | _ -> ());
      (match reconciled with
       | None -> already_goal_response ~tool_name ~start_time ~goal_id ~action
           ~phase:goal.phase goal record
       | Some (verdict, proof_record) ->
           emit_goal_event ctx ~goal_id ~event_type:"goal_phase"
             ~payload:(gate_event_payload ctx ~phase:goal.phase verdict);
           ok_result ~tool_name ~start_time
             [ "goal_id", `String goal_id; "action", `String (Goal_phase.action_to_string action)
             ; "noop", `Bool false; "reconciled", `Bool true
             ; "phase", Goal_phase.to_yojson goal.phase; "goal", Goal_store.goal_to_yojson goal
             ; "verification", Goal_verification.record_to_yojson_for_goal ~goal proof_record ])
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
          | Goal_phase.Awaiting_confirmation | Goal_phase.Completed | Goal_phase.Dropped -> true) ->
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
              | Goal_phase.Dropped ->
                already_goal_response
                  ~tool_name ~start_time ~goal_id ~action ~phase goal None)
           | Goal_phase.Public_action.Reopen ->
             finish_goal_reopen ~tool_name ~start_time ctx ~note goal
           | Goal_phase.Public_action.Drop ->
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
           | Goal_phase.Public_action.Drop ->
                (match update_goal_phase ctx goal ~phase ?note () with
                 | Error error ->
                   phase_write_error_result ~tool_name ~start_time error
                 | Ok updated_goal ->
                   notify_goal_verification_abandoned ctx ~goal_id;
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

let confirm_completion config ~goal_id ~operator_id ~request_id
    ~verification_run_id ~criterion_revision =
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
    let* confirming_operator = match record.Goal_verification.completion with
      | Goal_verification.Human_confirmed (_, confirmation) -> Ok confirmation.operator_id
      | _ -> Error "confirmation store did not retain operator authority" in
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
