(** Workspace_task_classify — State classification, task actor kind, working agents,
    event helpers.

    Extracted from Workspace_task to separate classification/observability helpers
    from task CRUD, claiming, and transitions.  All bindings are re-exported
    by [Workspace_task] via [include Workspace_task_classify]. *)

open Masc_domain
include Workspace_utils
include Workspace_state
open Workspace_backlog
open Workspace_identity
include Workspace_broadcast
open Workspace_backlog
open Workspace_identity

(* activity_workspace_id removed — namespace retired (#unify-namespace). *)

(* #9795: FSM drift observability. [masc_workspace] sits below the
   [masc] library in the dep graph, so it cannot call
   [Otel_metric_store.inc_counter] directly. The variant→label mapping
   stays here (pattern-matches the sealed drift enum), and the
   emit runs through a [Workspace_hooks] callback wired by
   [lib/workspace.ml] at startup.  Exhaustive pattern-match forces
   any new drift variant to be named alongside existing
   dashboards. *)
let drift_variant_label = function
  | Workspace_task_lifecycle.Claimed_to_done_skip -> "claimed_to_done_skip"
;;

(* #10449: classify a task's contract surface so the completion-path
   metric can split bypass-rate by creation-side data presence.
   Three states: missing field, present-but-empty, populated. *)
let classify_contract_state (contract : Masc_domain.task_contract option) =
  match contract with
  | None -> "no_contract"
  | Some c when c.completion_contract = [] && c.required_evidence = [] -> "empty_contract"
  | Some _ -> "with_contract"
;;

(* #10449: classify which FSM path produced a [Done] new_status.
   Approve_verification remains an explicit verification-submission path.
   Normal contracted [Done_action] completions are LLM-reviewed in
   [Tool_task] and then complete through the ordinary Done path. [forced_done]
   only fires when [force=true] short-circuited the same-agent guard;
   the lifecycle module emits the same drift variant for both forced
   and consensual claimed→done jumps, so the [force] flag is the
   only distinguisher. *)
let classify_completion_path
      ~(action : Masc_domain.task_action)
      ~(drift : Workspace_task_lifecycle.drift option)
      ~(force : bool)
  =
  match action with
  | Masc_domain.Approve_verification -> "via_verification"
  | Masc_domain.Claim | Masc_domain.Start | Masc_domain.Done_action
  | Masc_domain.Cancel | Masc_domain.Release
  | Masc_domain.Submit_for_verification | Masc_domain.Reject_verification ->
    if force then "forced_done"
    else (match drift with
          | Some Workspace_task_lifecycle.Claimed_to_done_skip -> "claimed_to_done_skip"
          | None -> "in_progress_to_done")
;;

let task_actor_kind agent_name =
  let normalized = String.lowercase_ascii (String.trim agent_name) in
  if normalized = "" || normalized = "system"
  then "system"
  else if Workspace_resilience.Zombie.is_keeper_name normalized
  then "keeper"
  else "agent"
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
    writers in [Workspace_agent.update_agent_r] correctly take
    [with_file_lock_r config agent_file], so concurrent
    [update_agent_r] or concurrent workspace_task transitions can race and
    lose each other's updates.

    This helper centralises the pattern, takes [with_file_lock] on the
    agent file, and silently skips the write when the file is missing
    (matching the pre-existing [if Sys.file_exists agent_file]
    guards).  It never blocks the caller on a missing/corrupt agent
    record — the backlog transition is the source of truth and the
    agent mirror is best-effort telemetry.  On JSON parse failure the
    error is logged with the agent name for diagnostic context. *)
let update_local_agent_state config ~agent_name f =
  let agent_file =
    Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
  in
  if Sys.file_exists agent_file
  then
    with_file_lock config agent_file (fun () ->
      let json = read_json config agent_file in
      match agent_of_yojson json with
      | Ok agent -> write_json config agent_file (agent_to_yojson (f agent))
      | Error msg ->
        Log.Misc.error "update_local_agent_state: parse failed for %s: %s" agent_name msg)
;;

(** Tighter variant of [resolve_agent_name] for task ownership guards.
    Only accepts the resolved identity when it is the exact [-agent] suffix
    form of the normalised input (e.g. "keeper-bob" -> "keeper-bob-agent").
    Arbitrary prefix matches from [resolve_agent_name] that do not conform to
    this pattern are silently discarded and the normalised input is returned
    unchanged, preventing one caller from being mistakenly mapped to a
    different agent's identity. *)
let resolve_agent_name_strict config agent_name =
  let normalized = String.lowercase_ascii (String.trim agent_name) in
  let resolved = resolve_agent_name config normalized in
  if resolved = normalized
  then normalized
  else if resolved = normalized ^ "-agent"
  then resolved
  else normalized
;;

let keeper_transport_alias_key name =
  let prefix = "keeper-" in
  let suffix = "-agent" in
  let prefix_len = String.length prefix in
  let suffix_len = String.length suffix in
  let len = String.length name in
  if
    len > prefix_len + suffix_len
    && String.starts_with ~prefix name
    && String.ends_with ~suffix name
  then Some (String.sub name prefix_len (len - prefix_len - suffix_len))
  else None
;;

let task_identity_key config name =
  let resolved = resolve_agent_name_strict config name in
  match keeper_transport_alias_key resolved with
  | Some keeper -> keeper
  | None ->
    if Nickname.is_dictionary_generated_nickname resolved
    then Option.value (Nickname.extract_agent_type resolved) ~default:resolved
    else resolved
;;

let same_task_actor config left right =
  String.equal (task_identity_key config left) (task_identity_key config right)
;;

let normalize_execution_links (links : Masc_domain.task_execution_links) =
  { operation_id = trim_opt links.operation_id
  ; session_id = trim_opt links.session_id
  }
;;

let normalize_task_contract (contract : Masc_domain.task_contract) =
  { contract with
    completion_contract = normalized_string_list contract.completion_contract
  ; required_evidence = normalized_string_list contract.required_evidence
  ; inspect_gate_evidence = normalized_string_list contract.inspect_gate_evidence
  ; verify_gate_evidence = normalized_string_list contract.verify_gate_evidence
  ; links = normalize_execution_links contract.links
  }
;;

let empty_task_contract =
  { strict = false
  ; completion_contract = []
  ; required_evidence = []
  ; inspect_gate_evidence = []
  ; verify_gate_evidence = []
  ; evidence_claims = []
  ; stale_claim_timeout_sec = 0
  ; links = { operation_id = None; session_id = None }
  }
;;

(* RFC-0311 Phase 1: the default verification contract declares no *specific*
   descriptive evidence entries. The prior default
   [ "completion_notes"; "reviewable_evidence_ref" ] could be satisfied only by
   pasting those two literal tokens into the completion notes (the gate matched
   them as substrings). That single mechanism simultaneously (a) over-blocked
   keepers who did not know the tokens and (b) let any completion be faked by
   pasting the labels. The completion gate ([Task_completion_gate]) no longer
   reads these entries at all: it accepts a completion only when the caller
   supplies at least one locally validated typed Evidence_ref (base-path file /
   file URI, local git commit, or local .masc trace/turn/receipt artifact) on
   handoff_context.evidence_refs — one flexible bar across code and non-code
   tasks. [required_evidence] now serves only as human/LLM/verifier
   description; typed-kind binding (a code task must cite a PR) is Phase 2. *)
let default_verification_evidence_refs = []

let first_line text =
  match String.index_opt text '\n' with
  | Some idx -> String.sub text 0 idx
  | None -> text
;;

let truncate ~max_len text =
  if String.length text <= max_len then text else String.sub text 0 max_len ^ "..."
;;

let default_completion_contract_text ~title ~description =
  let title = String.trim title in
  let description = description |> String.trim |> first_line in
  if description = ""
  then Printf.sprintf "Task scope satisfied: %s" title
  else
    truncate
      ~max_len:220
      (Printf.sprintf "Task scope satisfied: %s - %s" title description)
;;

let ensure_task_contract_for_verification ?contract ~title ~description () =
  let base =
    match contract with
    | Some contract -> normalize_task_contract contract
    | None -> empty_task_contract
  in
  let completion_contract =
    if base.completion_contract <> []
    then base.completion_contract
    else [ default_completion_contract_text ~title ~description ]
  in
  let required_evidence =
    if base.required_evidence <> []
    then base.required_evidence
    (* A verify-only task can require verifier input without widening the
       completion gate. Keep required_evidence empty in that case; the
       verifier projection combines verify_gate_evidence separately. *)
    else if base.verify_gate_evidence <> []
    then []
    else default_verification_evidence_refs
  in
  let verify_gate_evidence =
    if base.verify_gate_evidence <> []
    then base.verify_gate_evidence
    else required_evidence
  in
  normalize_task_contract
    { base with completion_contract; required_evidence; verify_gate_evidence }
;;

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

(** Merge optional OAS event_bus envelope identifiers (correlation_id,
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

let emit_task_activity ?correlation_id ?run_id config ~agent_name ~task_id ~kind ~payload =
  let payload = merge_envelope_into_payload ?correlation_id ?run_id payload in
  try
    (Atomic.get Workspace_hooks.activity_emit_fn)
      config
      ~actor:Workspace_hooks.{ kind = task_actor_kind agent_name; id = agent_name }
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
    fails for a reason other than ownership mismatch, surface what
    actions ARE legal from the current state so the LLM stops
    guess-retrying.

    Exhaustive [match] over [Masc_domain.task_status]: adding a 7th constructor
    will fail to compile. Each branch lists actions that
    [transition_task_r]'s match-arms accept for that status — keep this
    in sync if you add new transitions there. Verifier-FSM transitions
    require [MASC_VERIFICATION_FSM_ENABLED=true] but are listed
    unconditionally so the hint stays accurate when the flag is on; the
    flag-off case still rejects them and produces a more specific error. *)
let valid_next_actions_for_status
  : Masc_domain.task_status -> Masc_domain.task_action list
  = function
  | Masc_domain.Todo -> [ Masc_domain.Claim; Masc_domain.Release; Masc_domain.Cancel ]
  | Masc_domain.Claimed _ ->
    [ Masc_domain.Start
    ; Masc_domain.Done_action
    ; Masc_domain.Submit_for_verification
    ; Masc_domain.Release
    ; Masc_domain.Cancel
    ]
  | Masc_domain.InProgress _ ->
    [ Masc_domain.Done_action
    ; Masc_domain.Submit_for_verification
    ; Masc_domain.Release
    ; Masc_domain.Cancel
    ]
  | Masc_domain.AwaitingVerification _ ->
    [ Masc_domain.Approve_verification; Masc_domain.Reject_verification ]
  | Masc_domain.Done _ | Masc_domain.Cancelled _ | Masc_domain.OperatorBlocked _ -> [] (* terminal *)
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
  match status with
  | Masc_domain.Claimed { claimed_at; _ } ->
    Masc_domain.parse_iso8601 ~default_time claimed_at
  | Masc_domain.InProgress { started_at; _ } ->
    Masc_domain.parse_iso8601 ~default_time started_at
  | Masc_domain.Todo
  | Masc_domain.AwaitingVerification _
  | Masc_domain.Done _
  | Masc_domain.Cancelled _
  | Masc_domain.OperatorBlocked _ -> default_time
;;

let task_transition_details
      ~from_status
      ~to_status
      ?notes
      ?reason
      ?duration_ms
      ?(forced = false)
      ()
  =
  let optional_field name = function
    | Some value -> [ name, value ]
    | None -> []
  in
  `Assoc
    ([ "from_status", `String (task_status_to_string from_status)
     ; "to_status", `String (task_status_to_string to_status)
     ; "forced", `Bool forced
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
    preserves the legacy "action" field used by the unified transition path
    so existing dashboard readers do not break. *)
let transition_log_event
      ~(event_type : transition_event_type)
      ~agent_name
      ~task_id
      ~from_status
      ~to_status
      ?action
      ?notes
      ?reason
      ?duration_ms
      ?handoff_context
      ?(forced = false)
      ?(authority = Assignee)
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
     ; "actor_kind", `String (task_actor_kind agent_name)
     ; "task", `String task_id
     ; "from_status", `String (task_status_to_string from_status)
     ; "to_status", `String (task_status_to_string to_status)
     ; "forced", `Bool forced
       (* RFC-0262 §9: the typed authority the FSM granted this transition.
          [forced] is now the derived projection ([authority <> Assignee]); the
          §9 auditor (Completion_trust_audit) keys off [authority] to tell an
          Operator override from a System code-path satisfier. *)
     ; "authority", `String (completion_authority_to_string authority)
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
