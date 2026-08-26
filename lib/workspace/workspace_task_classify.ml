(** Workspace_task_classify — State classification, task actor kind, working agents,
    event helpers.

    Extracted from Workspace_task to separate classification/observability helpers
    from task CRUD, claiming, and transitions.  All bindings are re-exported
    by [Workspace_task] via [include Workspace_task_classify]. *)

open Masc_domain
include Workspace_utils
include Workspace_state
include Workspace_broadcast
open Workspace_backlog


type task_actor_kind =
  | Agent
  | Operator
  | System

let task_actor_kind_to_string = function
  | Agent -> "agent"
  | Operator -> "operator"
  | System -> "system"
;;

let trim_opt = Env_config_core.trim_opt

(* Agents who currently hold a Claimed or InProgress task.
    Used by the Hebbian hook to strengthen only against agents who are
    actively working, not everyone who happens to be joined.
    Falls back to active_agents if the backlog cannot be read. *)
let working_agents config =
  match read_backlog_r config with
  | Error _ -> (Workspace_state.read_state config).active_agents
  | Ok backlog ->
    List.filter_map
      (fun (t : task) ->
         match t.task_status with
         | Claimed { assignee; _ } | InProgress { assignee; _ } -> Some assignee
         | Todo | Done _ | Cancelled _ | AwaitingVerification _ -> None)
      backlog.tasks
    |> List.sort_uniq String.compare
;;

(** Update the on-disk agent state record under its own file lock.

    Task transitions ([claim], [complete], [cancel], …) need to
    reflect the new task assignment on the agent record at
    [<agents_dir>/<name>.json].  Every pre-existing call site in this
    module did the read→modify→write inline without holding any lock
    on that file — the enclosing [with_file_lock config backlog_path]
    only serializes backlog writers, not agent-state writers.  Sibling
    Other task writers correctly take
    [with_file_lock_r config agent_file], so concurrent
    workspace_task transitions cannot race and lose each other's updates.

    This helper centralises the pattern, takes [with_file_lock] on the
    agent file, and silently skips the write when the file is missing
    (the guard is backend-aware [path_exists config], so a Memory-backend
    workspace sees its own agent records).  It never blocks the caller on a missing/corrupt agent
    record — the backlog transition is the source of truth and the
    agent mirror is best-effort telemetry.  On JSON parse failure the
    error is logged with the agent name for diagnostic context. *)
let update_local_agent_state config ~agent_name f =
  let agent_file =
    Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
  in
  if path_exists config agent_file
  then
    with_file_lock config agent_file (fun () ->
      let json = read_json config agent_file in
      match agent_of_yojson json with
      | Ok agent -> write_json config agent_file (agent_to_yojson (f agent))
      | Error msg ->
        Log.Misc.error "update_local_agent_state: parse failed for %s: %s" agent_name msg)
;;

let same_task_actor _config left right =
  String.equal left right
;;

(** Trim and drop blanks from a contract a caller stated. Shaping only — there
    is deliberately no counterpart that produces a contract from a task that
    lacks one. A criterion derived from the title ("Task scope satisfied:
    <title>") answers "what counts as done" with "being done", so a verifier
    reading it learns nothing and falls back to a standard of its own, which
    the worker never sees. A task states its criteria or has none, and
    [contract = None] says which. *)
let normalize_task_contract (contract : Masc_domain.task_contract) =
  { contract with
    completion_contract = normalized_string_list contract.completion_contract
  ; required_evidence = normalized_string_list contract.required_evidence
  ; inspect_gate_evidence = normalized_string_list contract.inspect_gate_evidence
  ; verify_gate_evidence = normalized_string_list contract.verify_gate_evidence
  }
;;

(** Record which runtime carried the task out. Later identifiers win; blanks do
    not overwrite what is already recorded. *)
let merge_execution_links
      (existing : Masc_domain.task_execution_links)
      ?session_id
      ?operation_id
      ()
  =
  { session_id =
      (match trim_opt session_id with
       | Some _ as value -> value
       | None -> trim_opt existing.session_id)
  ; operation_id =
      (match trim_opt operation_id with
       | Some _ as value -> value
       | None -> trim_opt existing.operation_id)
  }
;;

(** Merge optional AGENT_CORE event_bus envelope identifiers (correlation_id,
    run_id) into the task activity payload. When both ids are absent the
    original payload is returned untouched, so existing callers compile
    and behave identically. *)
let merge_envelope_into_payload ?correlation_id ?run_id payload =
  let optional name = function
    | Some v -> [ name, `String v ]
    | None -> []
  in
  let extras = optional "correlation_id" correlation_id @ optional "run_id" run_id in
  if extras = []
  then payload
  else (
    match payload with
    | `Assoc fields -> `Assoc (fields @ extras)
    | _ ->
      Log.Misc.warn "emit_task_activity: non-Assoc payload, envelope fields skipped";
      payload)
;;

let emit_task_activity
    ?correlation_id
    ?run_id
    ?(actor_kind = Agent)
    config
    ~agent_name
    ~task_id
    ~kind
    ~payload
  =
  let payload = merge_envelope_into_payload ?correlation_id ?run_id payload in
  try
    (Atomic.get Workspace_hooks.activity_emit_fn)
      config
      ~actor:
        Workspace_hooks.
          { kind = task_actor_kind_to_string actor_kind
          ; id = agent_name
          }
      ~subject:Workspace_hooks.{ kind = "task"; id = task_id }
      ~kind
      ~payload
      ~tags:[ "task"; kind ]
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.warn ~keeper_name:task_id
      "task activity emit failed (%s %s): %s"
      kind
      task_id
      (Printexc.to_string exn)
;;

(* Issue #8354: was a verbatim duplicate of [Masc_domain.task_status_to_string].
   Folded to a single-line alias so adding a 7th task_status constructor
   only requires updating [Types]. The local name is kept so caller
   sites (224, 269, 863, 870, 1019, 1020) need no churn. *)
let task_status_to_string = Masc_domain.task_status_to_string

(** Current assignee from the task status, for error messages.
    LLMs that see "Invalid transition: claimed -> release" have no way
    to tell whether they're trying to release someone else's task vs
    using the wrong action name. Surfacing the current assignee in the
    failure lets the LLM see the ownership mismatch and stop retrying.

    Evidence: 2026-04-16 /loop iter 4 — 12+/15 masc_transition failures
    are "Invalid transition: claimed -> release" from keepers trying to
    release tasks owned by a different keeper. *)
let task_assignee_of_status = Masc_domain.task_assignee_of_status

(** Issue #7646: symmetric to [task_assignee_of_status]. When a transition
    fails for a reason other than ownership mismatch, surface what actions ARE
    legal from the current state so the LLM stops guess-retrying.

    Derived from the FSM rather than restated beside it. This was a
    hand-maintained match whose own doc said "keep this in sync if you add new
    transitions there", while [Workspace_task_lifecycle.valid_next_actions] —
    which asks [decide] directly and therefore cannot drift — sat unused next
    to it. The hint can no longer disagree with the transition it describes.

    [same_agent:true]: the hint is shown to the actor that just failed a
    transition on a task it owns. Ownership mismatch is reported separately and
    suppresses this hint entirely, so the not-same-agent projection is never
    the one rendered. *)
let valid_next_actions_for_status (status : Masc_domain.task_status) =
  Workspace_task_lifecycle.valid_next_actions ~same_agent:true ~task_status:status
;;

let next_actions_hint status =
  match valid_next_actions_for_status status with
  | [] -> ""
  | xs ->
    Printf.sprintf
      ", valid_next_actions=[%s]"
      (String.concat ";" (List.map Masc_domain.task_action_to_string xs))
;;

let task_started_at_unix status =
  let default_time = Time_compat.now () in
  let timestamp_or_default value =
    match Masc_domain.parse_iso8601_opt value with
    | Some timestamp -> timestamp
    | None -> default_time
  in
  match status with
  | Masc_domain.Claimed { claimed_at; _ } ->
    timestamp_or_default claimed_at
  | Masc_domain.InProgress { started_at; _ } ->
    timestamp_or_default started_at
  | Masc_domain.AwaitingVerification { started_at; _ } ->
    timestamp_or_default started_at
  | Masc_domain.Todo
  | Masc_domain.Done _
  | Masc_domain.Cancelled _ -> default_time
;;

let task_transition_details
      ~from_status
      ~to_status
      ?notes
      ?reason
      ?duration_ms
      ()
  =
  let optional_field name = function
    | Some value -> [ name, value ]
    | None -> []
  in
  `Assoc
    ([ "from_status", `String (task_status_to_string from_status)
     ; "to_status", `String (task_status_to_string to_status)
     ]
     @ optional_field "notes" (Option.map (fun value -> `String value) notes)
     @ optional_field "reason" (Option.map (fun value -> `String value) reason)
     @ optional_field "duration_ms" (Option.map (fun value -> `Int value) duration_ms))
;;

let observe_task_transition
      config
      ~agent_name
      ~task_id
      ~(transition : Masc_domain.task_action)
      ~details
  =
  (Atomic.get Workspace_hooks.observe_task_transition_fn)
    config
    ~agent_name
    ~task_id
    ~transition
    ~details
;;

(** Transition log event taxonomy. Variant instead of free-form string
    (#7520 Step 4) so typos at call-sites fail to compile. The two
    values correspond to the current fire points in this module — add
    a variant when a new transition event is introduced. *)
type transition_event_type =
  | Task_transition
  | Task_cancelled

let transition_event_type_to_string = function
  | Task_transition -> "task_transition"
  | Task_cancelled -> "task_cancelled"
;;

(** SSOT structured event for [log_event] sink. Wraps [task_transition_details]
    with an envelope (type/agent/actor_kind/task/from_status/to_status/ts) so
    every transition log line carries the same schema. Optional [?action]
    carries the typed transition label used by the unified transition path. *)
let transition_log_event
      ~(event_type : transition_event_type)
      ?(actor_kind = Agent)
      ~agent_name
      ~task_id
      ~from_status
      ~to_status
      ?action
      ?notes
      ?reason
      ?duration_ms
      ?handoff_context
      ?assignee
      ?(now = now_iso ())
      ()
  : Yojson.Safe.t
  =
  let optional_field name = function
    | Some value -> [ name, value ]
    | None -> []
  in
  `Assoc
    ([ "type", `String (transition_event_type_to_string event_type)
     ; "agent", `String agent_name
     ; "actor_kind", `String (task_actor_kind_to_string actor_kind)
     ; "task", `String task_id
     ; "from_status", `String (task_status_to_string from_status)
     ; "to_status", `String (task_status_to_string to_status)
     ; "ts", `String now
     ]
     (* RFC-0262 §9: the task's owner *before* this transition (the [from_status]
        assignee). Recorded so the §9① foreign-completion check is a direct
        [actor <> assignee] comparison instead of reconstructing ownership from
        the claim stream — the latter is blind to any claim outside the audited
        window. [None] for Todo / Cancelled from-states (no owner). *)
     @ optional_field "assignee" (Option.map (fun v -> `String v) assignee)
     @ optional_field "action" (Option.map (fun v -> `String v) action)
     @ optional_field "notes" (Option.map (fun v -> `String v) notes)
     @ optional_field "reason" (Option.map (fun v -> `String v) reason)
     @ optional_field "duration_ms" (Option.map (fun v -> `Int v) duration_ms)
     @ optional_field
         "handoff_context"
         (Option.map Masc_domain.task_handoff_context_to_yojson handoff_context))
;;
