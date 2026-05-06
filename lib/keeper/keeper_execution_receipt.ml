(* Receipt outcome classification. Mirrors the TLA+ spec
   [ReceiptOutcomeSet] (see [specs/keeper-turn-fsm/KeeperTurnFSM.tla] and
   [specs/keeper-state-machine/KeeperOutcomesConservation.tla]).
   [`Skipped] corresponds to TLA+ "receipt_skipped" produced by the
   [PhaseGateSkip] action: the turn reached terminal [Done] without
   dispatching, so it is a successful no-op rather than a failure or
   cancellation. The receipt record still stores the legacy string for
   JSON compatibility; consumers must go through these helpers so that
   Skipped/Cancelled/Error are not silently folded into one another. *)
type outcome_kind = [ `Ok | `Skipped | `Error | `Cancelled ]

let outcome_kind_to_string = function
  | `Ok -> "ok"
  | `Skipped -> "skipped"
  | `Error -> "error"
  | `Cancelled -> "cancelled"

let outcome_kind_to_tla_receipt = function
  | `Ok -> "receipt_done"
  | `Skipped -> "receipt_skipped"
  | `Error -> "receipt_failed"
  | `Cancelled -> "receipt_cancelled"

let outcome_kind_of_string = function
  | "ok" | "receipt_done" -> Some `Ok
  | "skipped" | "receipt_skipped" -> Some `Skipped
  | "error" | "receipt_failed" -> Some `Error
  | "cancelled" | "receipt_cancelled" -> Some `Cancelled
  | _ -> None

let outcome_kind_is_terminal_success = function
  | `Ok | `Skipped -> true
  | `Error | `Cancelled -> false

type error_kind = Error_kind of string

let error_kind_of_string value = Error_kind value
let error_kind_to_string (Error_kind value) = value

type cascade_name = Keeper_cascade_profile.runtime_name

let cascade_name_of_string = Keeper_cascade_profile.runtime_name_of_string
let cascade_name_to_string = Keeper_cascade_profile.runtime_name_to_string

(* TLA+ ReceiptIsAuthoritative invariant
   (specs/keeper-turn-fsm/KeeperTurnFSM.tla:336):
     receipt_outcome = "receipt_done" => turn_state = "done"
   Per ReceiptMatchesState the [Done] state also accepts receipt_skipped
   (PhaseGateSkip path), so this helper enforces the receipt-authoritative
   direction for both `Ok and `Skipped: a successful-terminal receipt
   MUST be paired with turn_state = "done". `Error and `Cancelled are
   left to ReceiptMatchesState (a separate invariant) and accepted here
   so this helper is single-concern. *)
type receipt_authority_violation = {
  outcome : string;
  turn_state : string;
}

let assert_receipt_authoritative ~outcome ~turn_state =
  match (outcome, turn_state) with
  | `Ok, "done" | `Skipped, "done" -> Ok ()
  | `Ok, other ->
      Error { outcome = "receipt_done"; turn_state = other }
  | `Skipped, other ->
      Error { outcome = "receipt_skipped"; turn_state = other }
  | (`Error | `Cancelled), _ -> Ok ()

type tool_requirement = Keeper_agent_tool_surface.tool_requirement

type tool_surface =
  { turn_lane : string
  ; tool_surface_class : string
  ; tool_requirement : Keeper_agent_tool_surface.tool_requirement
  ; visible_tool_count : int
  ; tool_gate_enabled : bool
  ; tool_surface_fallback_used : bool
  ; required_tools : string list
  ; missing_required_tools : string list
  }

type cascade_rotation_attempt =
  { from_cascade : cascade_name
  ; to_cascade : cascade_name
  ; reason : string
  ; outcome : string
  ; slot_release_at_phase : string option
  ; productive_phase_elapsed_ms : int option
  ; retry_phase_elapsed_ms : int option
  ; error_kind : error_kind option
  ; error_message : string option
  ; recorded_at : string
  }

type t =
  { keeper_name : string
  ; agent_name : string
  ; trace_id : string
  ; generation : int
  ; turn_count : int option
  ; current_task_id : string option
  ; goal_ids : string list
  ; outcome : string
  ; terminal_reason_code : string
  ; response_text_present : bool
  ; model_used : string option
  ; requested_tools : string list
  ; reported_tools : string list
  ; observed_tools : string list
  ; canonical_tools : string list
  ; unexpected_tools : string list
  ; tools_used : string list
  ; tool_contract_result : string
  ; tool_surface : tool_surface
  ; sandbox_kind : string
  ; sandbox_root : string option
  ; network_mode : string
  ; approval_profile : string option
  ; approval_profile_derived : bool
  ; cascade_name : cascade_name
  ; cascade_selected_model : string option
  ; cascade_attempt_count : int
  ; cascade_fallback_applied : bool
  ; cascade_outcome : string
  ; degraded_retry_applied : bool
  ; degraded_retry_cascade : cascade_name option
  ; fallback_reason : string option
  ; cascade_rotation_attempts : cascade_rotation_attempt list
  ; stop_reason : string option
  ; error_kind : error_kind option
  ; error_message : string option
  ; started_at : string
  ; ended_at : string
  }

let stop_reason_to_string = function
  | Oas_worker.Completed -> "completed"
  | Oas_worker.TurnBudgetExhausted { turns_used; limit } ->
    Printf.sprintf "turn_budget_exhausted:%d/%d" turns_used limit
  | Oas_worker.MutationBoundaryReached { turns_used; tool_name } ->
    (match tool_name with
     | Some tool ->
       Printf.sprintf "mutation_boundary:%s:%d" tool turns_used
     | None ->
       Printf.sprintf "mutation_boundary:%d" turns_used)

let sandbox_kind_of_meta (meta : Keeper_types.keeper_meta) =
  match meta.sandbox_profile with
  | Keeper_types.Docker -> "docker"
  | Keeper_types.Local -> "local"

let list_json values =
  `List (List.map (fun value -> `String value) values)

let string_opt_json = function
  | Some value -> `String value
  | None -> `Null

let last_nonempty values =
  List.fold_left
    (fun acc value ->
      if String.trim value = "" then acc else Some value)
    None values

let last_tool_name receipt =
  let rec choose = function
    | [] -> None
    | values :: rest -> (
        match last_nonempty values with
        | Some _ as value -> value
        | None -> choose rest)
  in
  choose
    [
      receipt.observed_tools;
      receipt.canonical_tools;
      receipt.tools_used;
      receipt.reported_tools;
      receipt.requested_tools;
    ]

let cascade_rotation_attempt_to_json attempt =
  `Assoc
    [
      ("from_cascade", `String (cascade_name_to_string attempt.from_cascade));
      ("to_cascade", `String (cascade_name_to_string attempt.to_cascade));
      ("reason", `String attempt.reason);
      ("outcome", `String attempt.outcome);
      ("slot_release_at_phase", string_opt_json attempt.slot_release_at_phase);
      ( "productive_phase_elapsed_ms",
        match attempt.productive_phase_elapsed_ms with
        | Some value -> `Int value
        | None -> `Null );
      ( "retry_phase_elapsed_ms",
        match attempt.retry_phase_elapsed_ms with
        | Some value -> `Int value
        | None -> `Null );
      ( "error_kind",
        string_opt_json (Option.map error_kind_to_string attempt.error_kind) );
      ("error_message", string_opt_json attempt.error_message);
      ("recorded_at", `String attempt.recorded_at);
    ]

let receipt_duration_ms receipt =
  match
    Masc_domain.parse_iso8601_opt receipt.started_at,
    Masc_domain.parse_iso8601_opt receipt.ended_at
  with
  | Some started_at, Some ended_at ->
    max 0.0 ((ended_at -. started_at) *. 1000.0)
  | _ -> 0.0

let string_contains_ci haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0 then true
    else if i + needle_len > haystack_len then false
    else if String.sub haystack i needle_len = needle then true
    else loop (i + 1)
  in
  loop 0

(* Cycle 51 observability: alert when [operator_disposition] cannot
   classify a receipt and falls through to the catch-all
   [("unknown", "unmapped_cascade_state")].

   PR #11651 fixed the historical "blocked" -> "unknown" silent path
   (livelock turns emitted [outcome="blocked"] which was not in
   [outcome_kind] and therefore mapped to the unknown bucket; the fix
   was to map livelock terminations to [outcome="error"] with
   [terminal_reason_code] carrying the specific reason).  After that
   fix the unmapped fall-through SHOULD be unreachable in production.

   This counter alerts operators if a future refactor reintroduces a
   silent path — a non-zero rate is a regression signal.  Companion
   to the existing PR #11651 narrative documented at the fall-through
   case below ([match outcome_kind_of_string ...] catch-all). *)
let () =
  Prometheus.register_counter
    ~name:Prometheus.metric_keeper_receipt_unmapped_disposition
    ~help:
      "Total receipts whose (outcome, cascade_outcome) tuple did not \
       match any branch of operator_disposition and fell through to \
       (\"unknown\", \"unmapped_cascade_state\").  PR #11651 fixed the \
       historical 'blocked' -> 'unknown' silent path; this counter \
       alerts operators if a future refactor reintroduces such a path. \
       A non-zero rate is a regression signal — investigate which \
       receipt.outcome / cascade_outcome / terminal_reason_code \
       combination is unclassified.  Labels are intentionally omitted: \
       receipt fields are high-cardinality free-form strings; \
       structured detail goes to the WARN log line at the firing site."
    ()

let operator_disposition (receipt : t) =
  let cascade_outcome = String.lowercase_ascii receipt.cascade_outcome in
  let terminal_reason = String.lowercase_ascii receipt.terminal_reason_code in
  let tool_contract_result =
    String.lowercase_ascii receipt.tool_contract_result
  in
  let error_kind =
    Option.map
      (fun kind -> String.lowercase_ascii (error_kind_to_string kind))
      receipt.error_kind
  in
  let provider_runtime_failure =
    String.starts_with ~prefix:"api_error_" terminal_reason
    || String.equal terminal_reason "provider_error"
    ||
    (match error_kind with
     | Some
         ( "api"
         | "mcp"
         | "io"
         | "orchestration"
         | "serialization" ) ->
         true
     | Some _ | None -> false)
  in
  let preflight_config_failure =
    match error_kind with
    | Some kind ->
        string_contains_ci kind "config"
        || string_contains_ci kind "auth"
        || string_contains_ci terminal_reason "config"
        || string_contains_ci terminal_reason "auth"
    | None ->
        string_contains_ci terminal_reason "config"
        || string_contains_ci terminal_reason "auth"
  in
  if
    String.equal terminal_reason "cascade_exhausted"
    || String.equal cascade_outcome "cascade_exhausted"
    || String.equal cascade_outcome "exhausted"
  then ("alert_exhausted", "cascade_exhausted")
  else if preflight_config_failure then
    ("pause_human", "preflight_config_error")
  else if
    provider_runtime_failure
    && (receipt.degraded_retry_applied
        || Option.is_some receipt.degraded_retry_cascade)
  then ("fail_open_next_cascade", "degraded_retry")
  else if
    provider_runtime_failure
    && (receipt.cascade_fallback_applied
        || String.equal cascade_outcome "passed_to_next_model")
  then ("pass_next_model", "cascade_fallback")
  else if provider_runtime_failure then
    ("pause_human", "provider_runtime_error")
  else if
    String.starts_with ~prefix:"completion_contract_violation:" terminal_reason
  then
    (* The downstream completion-contract layer has already decided the turn
       violated [require_tool_use] (or another contract sub-clause) and emits
       [terminal_reason="completion_contract_violation:<sub_clause>"]. The
       earlier-layer [tool_contract_result] can show [satisfied_completion]
       from a separate classifier that judged the same turn locally OK; the
       two-layer disagreement was the unmapped fall-through that #11651
       regression counter is meant to flag. Treat terminal_reason as
       authoritative — the disposition is the same as the explicit
       [tool_required_unsatisfied] branch below. *)
    ("pause_human", "tool_required_unsatisfied")
  else if
    receipt.tool_surface.tool_requirement = Required
    && (List.mem tool_contract_result
          [
            "violated";
            "unknown";
            "needs_execution_progress";
            "missing_required_tool_use";
            "passive_only";
            "claim_only_after_owned_task";
            "tool_surface_mismatch";
            "no_tool_capable_provider";
          ]
        || receipt.tools_used = [])
  then ("pause_human", "tool_required_unsatisfied")
  else if receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_cascade
  then ("fail_open_next_cascade", "degraded_retry")
  else if
    receipt.cascade_fallback_applied
    || String.equal cascade_outcome "passed_to_next_model"
  then ("pass_next_model", "cascade_fallback")
  (* "healthy" requires an explicit success signal: turn completed without
     error AND cascade reached the configured terminal. Any other fallthrough
     is an unmapped state — surface it as "unknown" so a new cascade_outcome
     or terminal_reason_code does not silently display as "healthy" on the
     dashboard. See #9900 and CLAUDE.md anti-pattern #2.

     Cancelled is split out from the legacy binary outcome so dashboards
     and replay decoders can distinguish a user-initiated cancellation
     from a true failure. Skipped corresponds to the TLA+ [PhaseGateSkip]
     action: a turn that intentionally never dispatched, so cascade
     never engaged. It is a successful no-op rather than a failure or
     an unmapped state. Spec parity with [ReceiptOutcomeSet] in
     [specs/keeper-turn-fsm/KeeperTurnFSM.tla]. *)
  else
    match outcome_kind_of_string receipt.outcome with
    | Some `Cancelled -> ("user_cancelled", "cancelled")
    | Some `Skipped -> ("skipped", "phase_skipped")
    | Some `Ok when String.equal cascade_outcome "completed" ->
      ("pass", "healthy")
    | _ ->
      Prometheus.inc_counter
        Prometheus.metric_keeper_receipt_unmapped_disposition ();
      Prometheus.inc_counter
        Prometheus.metric_keeper_execution_receipt_failures
        ~labels:[("keeper", receipt.keeper_name); ("site", "unmapped_disposition")]
        ();
      Log.Keeper.warn
        "operator_disposition: unmapped (outcome=%s cascade_outcome=%s \
         terminal_reason=%s tool_contract_result=%s error_kind=%s) \
         — investigate regression of #11651 silent-path fix"
        receipt.outcome cascade_outcome terminal_reason tool_contract_result
        (Option.value
           (Option.map error_kind_to_string receipt.error_kind)
           ~default:"<none>");
      ("unknown", "unmapped_cascade_state")

let to_json (receipt : t) =
  let operator_disposition, operator_disposition_reason =
    operator_disposition receipt
  in
  let error_json =
    match receipt.error_kind, receipt.error_message with
    | None, None -> `Null
    | error_kind, error_message ->
      `Assoc
        [
          ( "kind",
            match error_kind with
            | Some value -> `String (error_kind_to_string value)
            | None -> `Null );
          ( "message",
            match error_message with
            | Some value -> `String value
            | None -> `Null );
        ]
  in
  let runtime_contract =
    Keeper_runtime_contract.runtime_contract_json_from_fields
      ~keeper_name:receipt.keeper_name
      ~agent_name:receipt.agent_name
      ~trace_id:receipt.trace_id
      ~session_id:receipt.trace_id
      ~generation:receipt.generation
      ?keeper_turn_id:receipt.turn_count
      ?task_id:receipt.current_task_id
      ~goal_ids:receipt.goal_ids
      ~sandbox_profile:receipt.sandbox_kind
      ?sandbox_root:receipt.sandbox_root
      ~network_mode:receipt.network_mode
      ?approval_mode:receipt.approval_profile
      ~tool_surface_class:receipt.tool_surface.tool_surface_class
      ~visible_tool_count:receipt.tool_surface.visible_tool_count
      ~required_tools:receipt.tool_surface.required_tools
      ~missing_required_tools:receipt.tool_surface.missing_required_tools
      ?model:receipt.model_used
      ~cascade_profile:(cascade_name_to_string receipt.cascade_name)
      ()
  in
  let action_radius =
    Keeper_runtime_contract.action_radius_json
      ~tool_name:"keeper_turn"
      ~input:
        (`Assoc
           [
             ("action", `String "run_turn");
             ("target_kind", `String "keeper");
             ("target_path", string_opt_json receipt.sandbox_root);
           ])
      ~success:
        (match outcome_kind_of_string receipt.outcome with
         | Some kind -> outcome_kind_is_terminal_success kind
         | None -> false (* unknown outcome: fail-closed *))
      ~duration_ms:(receipt_duration_ms receipt)
      ?error:receipt.error_message
      ~sandbox_target:receipt.sandbox_kind
      ()
  in
  `Assoc
    [
      ("schema", `String "keeper.execution_receipt.v1");
      ("recorded_at", `String receipt.ended_at);
      ("keeper_name", `String receipt.keeper_name);
      ("agent_name", `String receipt.agent_name);
      ("trace_id", `String receipt.trace_id);
      ("generation", `Int receipt.generation);
      ( "turn_count",
        match receipt.turn_count with
        | Some value -> `Int value
        | None -> `Null );
      ( "current_task_id",
        match receipt.current_task_id with
        | Some value -> `String value
        | None -> `Null );
      ("goal_ids", list_json receipt.goal_ids);
      ("outcome",
       `String
         (match outcome_kind_of_string receipt.outcome with
          | Some kind -> outcome_kind_to_tla_receipt kind
          | None -> receipt.outcome));
      ("terminal_reason_code", `String receipt.terminal_reason_code);
      ("operator_disposition", `String operator_disposition);
      ("operator_disposition_reason", `String operator_disposition_reason);
      ("runtime_contract", runtime_contract);
      ("action_radius", action_radius);
      ("response_text_present", `Bool receipt.response_text_present);
      ( "model_used",
        match receipt.model_used with
        | Some value -> `String value
        | None -> `Null );
      ("requested_tools", list_json receipt.requested_tools);
      ("reported_tools", list_json receipt.reported_tools);
      ("observed_tools", list_json receipt.observed_tools);
      ("canonical_tools", list_json receipt.canonical_tools);
      ("unexpected_tools", list_json receipt.unexpected_tools);
      ("tools_used", list_json receipt.tools_used);
      ("tool_contract_result", `String receipt.tool_contract_result);
      ( "tool_surface",
        `Assoc
          [
            ("turn_lane", `String receipt.tool_surface.turn_lane);
            ("tool_surface_class", `String receipt.tool_surface.tool_surface_class);
            ("tool_requirement", Keeper_agent_tool_surface.tool_requirement_to_yojson receipt.tool_surface.tool_requirement);
            ("visible_tool_count", `Int receipt.tool_surface.visible_tool_count);
            ("tool_gate_enabled", `Bool receipt.tool_surface.tool_gate_enabled);
            ( "tool_surface_fallback_used",
              `Bool receipt.tool_surface.tool_surface_fallback_used );
            ("required_tools", list_json receipt.tool_surface.required_tools);
            ( "missing_required_tools",
              list_json receipt.tool_surface.missing_required_tools );
          ] );
      ( "sandbox",
        `Assoc
          [
            ("kind", `String receipt.sandbox_kind);
            ( "sandbox_root",
              match receipt.sandbox_root with
              | Some value -> `String value
              | None -> `Null );
            ("network_mode", `String receipt.network_mode);
          ] );
      ( "approval",
        `Assoc
          [
            ( "profile",
              match receipt.approval_profile with
              | Some value -> `String value
              | None -> `Null );
            ("derived", `Bool receipt.approval_profile_derived);
          ] );
      ( "cascade",
        `Assoc
          [
            ("name", `String (cascade_name_to_string receipt.cascade_name));
            ( "selected_model",
              match receipt.cascade_selected_model with
              | Some value -> `String value
              | None -> `Null );
            ("attempt_count", `Int receipt.cascade_attempt_count);
            ("fallback_applied", `Bool receipt.cascade_fallback_applied);
            ("outcome", `String receipt.cascade_outcome);
            ("degraded_retry_applied", `Bool receipt.degraded_retry_applied);
            ( "degraded_retry_cascade",
              match receipt.degraded_retry_cascade with
              | Some value -> `String (cascade_name_to_string value)
              | None -> `Null );
            ( "fallback_reason",
              match receipt.fallback_reason with
              | Some value -> `String value
              | None -> `Null );
            ( "rotation_attempts",
              `List
                (List.map cascade_rotation_attempt_to_json
                   receipt.cascade_rotation_attempts) );
          ] );
      ( "stop_reason",
        match receipt.stop_reason with
        | Some value -> `String value
        | None -> `Null );
      ("error", error_json);
      ("started_at", `String receipt.started_at);
      ("ended_at", `String receipt.ended_at);
    ]

(* Operator broadcast hook (#fleet-stall 2026-04-26): operator_disposition
   was a derived display field — emitted nowhere. A pause_human/alert_exhausted
   verdict therefore had no transition out: dashboard turned a chip red, but
   no event reached operators and no supervisor handoff fired. We now emit a
   structured "keeper.operator_broadcast_required" activity event so the gate
   verdict becomes addressable instead of cosmetic.

   Spec navigation (OCaml -> TLA+) — plan §19 anchor pattern.
   Authoritative spec mirror is
   [specs/keeper-state-machine/OperatorPauseBroadcast.tla].

   Spec lines 17-21 already cite this module:
     "lib/keeper/keeper_execution_receipt.ml: needs_operator_broadcast +
      emit_operator_broadcast called from append".

   This block is the reverse-direction citation so code search for
   "OperatorPauseBroadcast" lands at this hook.

   Spec property under audit (line 11-15):
     For every keeper that enters PauseHuman or StaleRunning, an
     OperatorBroadcast event is eventually emitted (leads-to).  The
     clean Spec satisfies this; the bug model where emit is silently
     dropped MUST violate it.

   OCaml mapping:
     PauseHuman / StaleRunning  -> [needs_operator_broadcast]
                                  returns [true] for "pause_human",
                                  "alert_exhausted", "unknown".
     OperatorBroadcast event    -> [emit_operator_broadcast]
                                  emits "keeper.operator_broadcast_required.v1"
                                  with structured payload.
     Eventually-emit liveness   -> [append] (~line 455) calls the
                                  emit unconditionally when
                                  [needs_operator_broadcast] is true,
                                  inside a [try] so a single failure
                                  does not cascade — the spec's clean
                                  model.

   Bug model (would be violated if a future refactor wrapped emit
   in a conditional that could silently skip): an OperatorBroadcast
   path that requires manual operator dispatch instead of automatic
   emit would re-create the original #fleet-stall bug.  Sibling
   anchor in [keeper_supervisor.ml] (StaleRunning watchdog +
   emit_stale_keeper_broadcast) is deferred to a separate cycle. *)
let needs_operator_broadcast = function
  | "pause_human" | "alert_exhausted" | "unknown" -> true
  | _ -> false

let operator_broadcast_payload (receipt : t) ~disposition ~reason =
  `Assoc
    [ "schema", `String "keeper.operator_broadcast_required.v1"
    ; "keeper_name", `String receipt.keeper_name
    ; "agent_name", `String receipt.agent_name
    ; "trace_id", `String receipt.trace_id
    ; "generation", `Int receipt.generation
    ; ( "turn_count",
        match receipt.turn_count with
        | Some value -> `Int value
        | None -> `Null )
    ; "disposition", `String disposition
    ; "disposition_reason", `String reason
    ; "outcome",
      `String
        (match outcome_kind_of_string receipt.outcome with
         | Some kind -> outcome_kind_to_tla_receipt kind
         | None -> receipt.outcome)
    ; "terminal_reason_code", `String receipt.terminal_reason_code
    ; ( "current_task_id",
        match receipt.current_task_id with
        | Some value -> `String value
        | None -> `Null )
    ; "goal_ids", list_json receipt.goal_ids
    ; "response_text_present", `Bool receipt.response_text_present
    ; "cascade_name", `String (cascade_name_to_string receipt.cascade_name)
    ; "cascade_outcome", `String receipt.cascade_outcome
    ; "tool_contract_result", `String receipt.tool_contract_result
    ; ( "last_tool_name",
        match last_tool_name receipt with
        | Some value -> `String value
        | None -> `Null )
    ; "tools_used", list_json receipt.tools_used
    ; ( "tool_contract",
        `Assoc
          [ "result", `String receipt.tool_contract_result
          ; "required_tools", list_json receipt.tool_surface.required_tools
          ; ( "missing_required_tools",
              list_json receipt.tool_surface.missing_required_tools )
          ; "visible_tool_count", `Int receipt.tool_surface.visible_tool_count
          ; "tool_requirement", Keeper_agent_tool_surface.tool_requirement_to_yojson receipt.tool_surface.tool_requirement
          ; "tool_surface_class", `String receipt.tool_surface.tool_surface_class
          ; "tool_gate_enabled", `Bool receipt.tool_surface.tool_gate_enabled
          ] )
    ; ( "sandbox",
        `Assoc
          [ "kind", `String receipt.sandbox_kind
          ; "sandbox_root", string_opt_json receipt.sandbox_root
          ; "network_mode", `String receipt.network_mode
          ] )
    ; ( "model_used",
        match receipt.model_used with
        | Some value -> `String value
        | None -> `Null )
    ; ( "stop_reason",
        match receipt.stop_reason with
        | Some value -> `String value
        | None -> `Null )
    ; ( "error_kind",
        match receipt.error_kind with
        | Some v -> `String (error_kind_to_string v)
        | None -> `Null )
    ; ( "error_message",
        match receipt.error_message with
        | Some v -> `String v
        | None -> `Null )
    ; "ended_at", `String receipt.ended_at
    ]

let emit_operator_broadcast config (receipt : t) ~disposition ~reason =
  let payload = operator_broadcast_payload receipt ~disposition ~reason in
  let event =
    Activity_graph.emit config
      ~actor:{ Activity_graph.kind = "agent"; id = receipt.agent_name }
      ~kind:"keeper.operator_broadcast_required"
      ~payload
      ()
  in
  Log.Keeper.info
    "%s: operator_broadcast_required emitted disposition=%s reason=%s seq=%d"
    receipt.keeper_name disposition reason event.seq

let append (config : Coord.config) (receipt : t) =
  let store =
    Keeper_types_support.keeper_execution_receipt_store config
      receipt.keeper_name
  in
  Dated_jsonl.append store (to_json receipt);
  let disposition, reason = operator_disposition receipt in
  if needs_operator_broadcast disposition then
    try emit_operator_broadcast config receipt ~disposition ~reason with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      (* fail-closed: log loud, do not silently swallow. The append itself
         has already persisted the receipt; the broadcast failure is its
         own diagnostic that watchdogs/log alerts will pick up. *)
      Prometheus.inc_counter
        Prometheus.metric_keeper_execution_receipt_failures
        ~labels:[("keeper", receipt.keeper_name); ("site", "emit_failed")]
        ();
      Log.Keeper.error
        "%s: operator_broadcast_required EMIT FAILED disposition=%s \
         reason=%s exn=%s"
        receipt.keeper_name disposition reason (Printexc.to_string exn)

(* Watchdog-driven broadcast (#fleet-stall 2026-04-26 Step 3): emitted by a
   supervisor-side fiber when a Running keeper has not produced a turn for
   longer than the stale threshold. This is the path that catches the
   "KSM=Running but no live turn" failure mode where the heartbeat fiber is
   blocked on a long call and would otherwise never produce a receipt. *)
let stale_kill_class_label = function
  | Keeper_registry.Idle_turn _ -> "idle_turn"
  | Keeper_registry.In_turn_hung _ -> "in_turn_hung"
  | Keeper_registry.Noop_failure_loop _ -> "noop_failure_loop"

let stale_terminal_reason_code = function
  | Some (Keeper_registry.Provider_runtime_error { code; _ }) -> code
  | Some (Keeper_registry.Tool_required_unsatisfied { code; _ }) -> code
  | Some (Keeper_registry.Oas_timeout_budget_loop _) -> "oas_timeout_budget"
  | Some (Keeper_registry.Stale_turn_timeout _) -> "stale_turn_timeout"
  | Some (Keeper_registry.Stale_termination_storm _) ->
      "stale_termination_storm"
  | Some (Keeper_registry.Heartbeat_consecutive_failures _) ->
      "heartbeat_failures"
  | Some (Keeper_registry.Turn_consecutive_failures _) -> "turn_failures"
  | Some (Keeper_registry.Ambiguous_partial_commit _) ->
      "ambiguous_partial_commit"
  | Some Keeper_registry.Fiber_unresolved -> "fiber_unresolved"
  | Some (Keeper_registry.Exception _) -> "exception"
  | None -> "stale_turn_timeout"

let stale_broadcast_failure_cohort = function
  | Some _ as reason -> Keeper_registry.failure_reason_cohort_key reason
  | None -> "stale_turn_timeout"

let stale_broadcast_kill_class = function
  | Some (Keeper_registry.Stale_turn_timeout cls) ->
      Some (stale_kill_class_label cls)
  | _ -> None

let stale_turn_bucket stale_seconds =
  if stale_seconds < 30.0 then "stale_turn_lt_30s"
  else if stale_seconds < 60.0 then "stale_turn_30s_to_60s"
  else if stale_seconds < 300.0 then "stale_turn_1m_to_5m"
  else if stale_seconds < 600.0 then "stale_turn_5m_to_10m"
  else if stale_seconds < 1_800.0 then "stale_turn_10m_to_30m"
  else "stale_turn_ge_30m"

let stale_broadcast_payload
    ~keeper_name ~agent_name ~cascade_name ~trace_id ~generation
    ~failure_reason
    ~stale_seconds ~last_turn_ts =
  let cascade_name_string = cascade_name_to_string cascade_name in
  let failure_reason_text =
    Option.map Keeper_registry.failure_reason_to_string failure_reason
  in
  let failure_reason_cohort = stale_broadcast_failure_cohort failure_reason in
  `Assoc
    [ "schema", `String "keeper.operator_broadcast_required.v1"
    ; "keeper_name", `String keeper_name
    ; "agent_name", `String agent_name
    ; "cascade_name", `String cascade_name_string
    ; "trace_id", `String trace_id
    ; "generation", `Int generation
    ; "disposition", `String "stalled"
    ; "disposition_reason", `String failure_reason_cohort
    ; "terminal_reason_code", `String (stale_terminal_reason_code failure_reason)
    ; "failure_reason", string_opt_json failure_reason_text
    ; "failure_reason_cohort", `String failure_reason_cohort
    ; "stale_kill_class", string_opt_json (stale_broadcast_kill_class failure_reason)
    ; "stale_turn_bucket", `String (stale_turn_bucket stale_seconds)
    ; "stale_seconds", `Float stale_seconds
    ; "last_turn_ts", `Float last_turn_ts
    ; "source", `String "watchdog"
    ]

let emit_stale_keeper_broadcast config
    ~keeper_name ~agent_name ~cascade_name ~trace_id ~generation
    ~failure_reason ~stale_seconds ~last_turn_ts =
  let cascade_name_string = cascade_name_to_string cascade_name in
  let payload =
    stale_broadcast_payload ~keeper_name ~agent_name
      ~cascade_name ~trace_id ~generation ~stale_seconds ~last_turn_ts
      ~failure_reason
  in
  let event =
    Activity_graph.emit config
      ~actor:{ Activity_graph.kind = "watchdog"; id = keeper_name }
      ~kind:"keeper.operator_broadcast_required"
      ~payload
      ()
  in
  Prometheus.inc_counter
    Prometheus.metric_keeper_execution_receipt_failures
    ~labels:[("keeper", keeper_name); ("site", "stale_broadcast")]
    ();
  Log.Keeper.error
    "%s: stale_keeper_broadcast emitted last_turn=%.0fs ago cascade=%s seq=%d"
    keeper_name stale_seconds cascade_name_string event.seq

let latest_json (config : Coord.config) keeper_name =
  let store =
    Keeper_types_support.keeper_execution_receipt_store config keeper_name
  in
  match Dated_jsonl.read_recent store 1 with
  | [ json ] -> Some json
  | _ -> None

let latest_json_by_keeper (config : Coord.config) keeper_names =
  keeper_names
  |> List.filter_map (fun keeper_name ->
         match latest_json config keeper_name with
         | Some json -> Some (keeper_name, json)
         | None -> None)
