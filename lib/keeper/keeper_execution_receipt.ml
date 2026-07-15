(* Types, classification, and JSON helpers extracted to
   [Keeper_execution_receipt_types] (godfile decomp). *)
include Keeper_execution_receipt_types


let runtime_rotation_attempt_to_json attempt =
  `Assoc
    [ "from_runtime", `String (attempt.from_runtime)
    ; "to_runtime", `String (attempt.to_runtime)
    ; ( "reason"
      , `String (Keeper_error_classify.degraded_retry_reason_to_string attempt.reason) )
    ; "outcome", `String (runtime_rotation_outcome_to_string attempt.outcome)
    ; ( "productive_phase_elapsed_ms"
      , Json_util.int_opt_to_json attempt.productive_phase_elapsed_ms )
    ; ( "retry_phase_elapsed_ms"
      , Json_util.int_opt_to_json attempt.retry_phase_elapsed_ms )
    ; "error_kind", string_opt_json (Option.map error_kind_to_string attempt.error_kind)
    ; "error_message", string_opt_json attempt.error_message
    ; "recorded_at", `String attempt.recorded_at
    ]
;;

let receipt_duration_ms receipt =
  match
    ( Masc_domain.parse_iso8601_opt receipt.started_at
    , Masc_domain.parse_iso8601_opt receipt.ended_at )
  with
  | Some started_at, Some ended_at -> max 0.0 ((ended_at -. started_at) *. 1000.0)
  | _ -> 0.0
;;

(* Cycle 51 observability: alert when [operator_disposition] cannot
   classify a receipt and falls through to the catch-all
   [(Disp_unknown, Reason_unmapped_runtime_state)].

   This counter alerts operators if a future refactor reintroduces a
   silent path — a non-zero rate is a regression signal.  Companion
   to the existing PR #11651 narrative documented at the fall-through
   case below ([match outcome_kind_of_string ...] catch-all). *)
let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string ReceiptUnmappedDisposition)
    ~help:
      "Total receipts whose (outcome, runtime_outcome) tuple did not match any branch of \
       operator_disposition and fell through to the typed catch-all \
       (Disp_unknown, Reason_unmapped_runtime_state).  PR #11651 fixed the historical \
       'blocked' -> 'unknown' silent path; this counter alerts operators if a future \
       refactor reintroduces such a path. A non-zero rate is a regression signal — \
       investigate which receipt.outcome / runtime_outcome / terminal_reason_code \
       combination is unclassified.  Labels are intentionally omitted: receipt fields \
       are high-cardinality free-form strings; structured detail goes to the WARN log \
       line at the firing site."
    ()
;;

type operator_disposition_kind =
  | Disp_pass
  | Disp_fail_open_next_runtime
  | Disp_pass_next_model
  | Disp_user_cancelled
  | Disp_skipped
  | Disp_unknown

let operator_disposition_kind_to_string = function
  | Disp_pass -> "pass"
  | Disp_fail_open_next_runtime -> "fail_open_next_runtime"
  | Disp_pass_next_model -> "pass_next_model"
  | Disp_user_cancelled -> "user_cancelled"
  | Disp_skipped -> "skipped"
  | Disp_unknown -> "unknown"
;;

let operator_disposition_kind_of_string = function
  | "pass" -> Some Disp_pass
  | "fail_open_next_runtime" -> Some Disp_fail_open_next_runtime
  | "pass_next_model" -> Some Disp_pass_next_model
  | "user_cancelled" -> Some Disp_user_cancelled
  | "skipped" -> Some Disp_skipped
  | "unknown" -> Some Disp_unknown
  | _ -> None
;;

type operator_disposition_reason =
  | Reason_healthy
  | Reason_runtime_exhausted
  | Reason_preflight_config_error
  | Reason_degraded_retry
  | Reason_runtime_fallback
  | Reason_transient_runtime_retry
  | Reason_capacity_backpressure
  | Reason_provider_runtime_error
  | Reason_internal_error
  | Reason_input_required
  | Reason_cancelled
  | Reason_phase_skipped
  | Reason_unmapped_runtime_state

let operator_disposition_reason_to_string = function
  | Reason_healthy -> "healthy"
  | Reason_runtime_exhausted -> "runtime_exhausted"
  | Reason_preflight_config_error -> "preflight_config_error"
  | Reason_degraded_retry -> "degraded_retry"
  | Reason_runtime_fallback -> "runtime_fallback"
  | Reason_transient_runtime_retry -> "transient_runtime_retry"
  | Reason_capacity_backpressure -> Keeper_internal_error.capacity_backpressure_kind
  | Reason_provider_runtime_error -> "provider_runtime_error"
  | Reason_internal_error -> "internal_error"
  | Reason_input_required -> "input_required"
  | Reason_cancelled -> "cancelled"
  | Reason_phase_skipped -> "phase_skipped"
  | Reason_unmapped_runtime_state -> "unmapped_runtime_state"
;;

let operator_disposition (receipt : t)
  : operator_disposition_kind * operator_disposition_reason
  =
  (* Parse the wire string ONCE into the typed classification
     ([Keeper_terminal_reason], RFC-0042 PR-4). The earlier
     [String.starts_with] / [string_contains] chain is now a single
     [of_wire] call; each former string predicate is a variant test,
     preserving the original [if/else] priority order. The error_kind
     sub-predicates stay here (they read the receipt record, not the wire
     string) and remain OR'd with the variant test at the same branch. *)
  let terminal_reason = Keeper_terminal_reason.of_wire receipt.terminal_reason_code in
  let input_required =
    let open Keeper_turn_disposition in
    match Keeper_turn_disposition.of_wire receipt.terminal_reason_code with
    | Input_required -> true
    | Success
    | External_cancel
    | Turn_wall_clock_timeout
    | Runtime_attempts_exhausted
    | Provider_error _
    | Unknown _ -> false
  in
  let provider_runtime_failure =
    match terminal_reason with
    | Keeper_terminal_reason.Provider_runtime_failure _ -> true
    | _ -> false
  in
  let preflight_config_failure =
    match terminal_reason with
    | Keeper_terminal_reason.Config_or_auth _ -> true
    | _ -> false
  in
  (* Pre-typing, this branch also matched runtime_outcome="runtime_exhausted"
     and "exhausted" — neither is in the producer's closed [runtime_outcome]
     set ([Runtime_passed_to_next_model] / [_completed] / [_failed] /
     [_not_observed] / [_not_dispatched]).  Those branches were unreachable workarounds; the
     typed migration drops them.  Runtime exhaustion still reaches this
     branch via [terminal_reason="runtime_exhausted"]. *)
  match terminal_reason with
  | _ when input_required -> Disp_pass, Reason_input_required
  | Keeper_terminal_reason.Runtime_exhausted _ ->
    Disp_fail_open_next_runtime, Reason_runtime_exhausted
  | Keeper_terminal_reason.Capacity_backpressure _ ->
    (* The typed runtime route treats provider-capacity failure as retryable and
       continues with another eligible runtime.  This receipt is written for
       the failed pre-dispatch attempt before that rotation is reflected in
       [runtime_fallback_applied], so it must neither claim a completed
       fallback nor page a human. *)
    Disp_fail_open_next_runtime, Reason_capacity_backpressure
  | _ when preflight_config_failure ->
    Disp_fail_open_next_runtime, Reason_preflight_config_error
  | _
    when provider_runtime_failure
         && (receipt.degraded_retry_applied
             || Option.is_some receipt.degraded_retry_runtime) ->
    Disp_fail_open_next_runtime, Reason_degraded_retry
  | _
    when provider_runtime_failure
         && (receipt.runtime_fallback_applied
             || receipt.runtime_outcome = Runtime_passed_to_next_model) ->
    Disp_pass_next_model, Reason_runtime_fallback
  | _
    when provider_runtime_failure
         && Keeper_terminal_reason.is_transient_provider_runtime_failure
              terminal_reason ->
    (* The reason is [Reason_transient_runtime_retry], not
       [Reason_runtime_fallback]: this arm is reached only AFTER the
       runtime-fallback arm above excluded [runtime_fallback_applied] /
       [Runtime_passed_to_next_model], so by construction no cross-runtime
       fallback happened — the turn recovered via the SAME runtime's in-turn
       retry. [operator_disposition_reason] is serialised into receipt JSON
       unconditionally (dashboard-visible), so collapsing this onto the
       fallback label would mislabel every transient-recovery turn as a
       genuine fallback. *)
    Disp_fail_open_next_runtime, Reason_transient_runtime_retry
  | _ when provider_runtime_failure ->
    Disp_fail_open_next_runtime, Reason_provider_runtime_error
  | Keeper_terminal_reason.Internal_error _ ->
    Disp_fail_open_next_runtime, Reason_internal_error
  | Config_or_auth _
  | Provider_runtime_failure _
  | Pre_dispatch_success _
  | Unknown _ ->
    (* Generic fall-through. [Config_or_auth] and
       [Provider_runtime_failure] are caught by the guarded branches above
       (their constructors force [preflight_config_failure] /
       [provider_runtime_failure] true), so only [Pre_dispatch_success] and
       [Unknown] reach here in practice;
       [Config_or_auth] and [Provider_runtime_failure] are listed to keep the
       match exhaustive without a wildcard. *)
    if receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_runtime
    then Disp_fail_open_next_runtime, Reason_degraded_retry
    else if
      receipt.runtime_fallback_applied
      || receipt.runtime_outcome = Runtime_passed_to_next_model
    then Disp_pass_next_model, Reason_runtime_fallback
    else if
      receipt.outcome = `Ok
      && receipt.runtime_outcome = Runtime_not_dispatched
      &&
      (match terminal_reason with
       | Keeper_terminal_reason.Pre_dispatch_success _ -> true
       | Runtime_exhausted _
       | Capacity_backpressure _
       | Config_or_auth _
       | Provider_runtime_failure _
       | Internal_error _
       | Unknown _ -> false)
    then Disp_pass, Reason_healthy
    (* "healthy" requires an explicit success signal: turn completed without
       error AND runtime reached the configured terminal. Any other fallthrough
       is an unmapped state — surface it as "unknown" so a new runtime_outcome
       or terminal_reason_code does not silently display as "healthy" on the
       dashboard. See #9900 and CLAUDE.md anti-pattern #2.

       Cancelled is split out from the legacy binary outcome so dashboards
       and replay decoders can distinguish a user-initiated cancellation
       from a true failure. Skipped corresponds to the TLA+ [PhaseGateSkip]
       action: a turn that intentionally never dispatched, so runtime
       never engaged. It is a successful no-op rather than a failure or
       an unmapped state. Spec parity with [ReceiptOutcomeSet] in
       [specs/keeper-turn-fsm/KeeperTurnFSM.tla]. *)
    else (
      match receipt.outcome with
      | `Cancelled -> Disp_user_cancelled, Reason_cancelled
      | `Skipped -> Disp_skipped, Reason_phase_skipped
      | `Ok when receipt.runtime_outcome = Runtime_completed -> Disp_pass, Reason_healthy
      | `Ok when receipt.runtime_outcome = Runtime_not_dispatched ->
        (* Pre-dispatch shortcut: the turn completed successfully without
           dispatching to the LLM (cached response, immediate tool result,
           or pre-dispatch check resolved the turn).  Treated as healthy
           because the outcome is success — the runtime was simply not
           needed.  Previously unmapped (1062 WARN/day on 2026-05-24). *)
        Disp_pass, Reason_healthy
      | _ ->
        Otel_metric_store.inc_counter Keeper_metrics.(to_string ReceiptUnmappedDisposition) ();
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string ExecutionReceiptFailures)
          ~labels:[ "keeper", receipt.keeper_name; "site", Keeper_execution_receipt_failure_site.(to_label Unmapped_disposition) ]
          ();
        Log.Keeper.warn
          ~keeper_name:receipt.keeper_name
          "operator_disposition: unmapped (outcome=%s runtime_outcome=%s \
           terminal_reason=%s completion_contract_result=%s error_kind=%s) — investigate \
           regression of #11651 silent-path fix"
          (outcome_kind_to_string receipt.outcome)
          (runtime_outcome_to_string receipt.runtime_outcome)
          receipt.terminal_reason_code
          (completion_contract_result_to_string receipt.completion_contract_result)
          (Option.value
             (Option.map error_kind_to_string receipt.error_kind)
             ~default:"<none>");
        Disp_unknown, Reason_unmapped_runtime_state)
;;

let to_json_with_operator_disposition
      (receipt : t)
      ~disposition
      ~disposition_reason
  =
  let terminal_reason_code = receipt.terminal_reason_code in
  let operator_disposition = operator_disposition_kind_to_string disposition in
  let operator_disposition_reason =
    operator_disposition_reason_to_string disposition_reason
  in
  let error_json =
    match receipt.error_kind, receipt.error_message with
    | None, None -> `Null
    | error_kind, error_message ->
      `Assoc
        [ ( "kind"
          , string_opt_json (Option.map error_kind_to_string error_kind) )
        ; ( "message", string_opt_json error_message )
        ]
  in
  let runtime_contract =
    Keeper_runtime_contract.runtime_observability_contract_json_from_fields
      ~keeper_name:receipt.keeper_name
      ~agent_name:receipt.agent_name
      ~trace_id:receipt.trace_id
      ~session_id:receipt.trace_id
      ~generation:receipt.generation
      ?keeper_turn_id:receipt.turn_count
      ?task_id:receipt.current_task_id
      ~sandbox_profile:(Keeper_types_profile_sandbox.sandbox_profile_to_string receipt.sandbox_kind)
      ?sandbox_root:receipt.sandbox_root
      ~network_mode:(Keeper_types_profile_sandbox.network_mode_to_string receipt.network_mode)
      ~runtime_profile:(receipt.runtime_id)
      ()
  in
  let action_radius =
    Keeper_runtime_contract.action_radius_json
      ~tool_name:"keeper_turn"
      ~input:
        (`Assoc
            [ "action", `String "run_turn"
            ; "target_kind", `String "keeper"
            ; "target_path", string_opt_json receipt.sandbox_root
            ])
      ~success:(outcome_kind_is_terminal_success receipt.outcome)
      ~duration_ms:(receipt_duration_ms receipt)
      ?error:receipt.error_message
      ~sandbox_target:(Keeper_types_profile_sandbox.sandbox_profile_to_string receipt.sandbox_kind)
      ()
  in
  `Assoc
    [ "schema", `String Keeper_types_support.execution_receipt_schema
    ; "recorded_at", `String receipt.ended_at
    ; "keeper_name", `String receipt.keeper_name
    ; "agent_name", `String receipt.agent_name
    ; "trace_id", `String receipt.trace_id
    ; "generation", `Int receipt.generation
    ; ( "turn_count", Json_util.int_opt_to_json receipt.turn_count )
    ; ( "oas_turn_count", Json_util.int_opt_to_json receipt.oas_turn_count )
    ; ( "oas_dispatch_mode", string_opt_json receipt.oas_dispatch_mode )
    ; ( "oas_internal_runtime_disabled"
      , `Bool receipt.oas_internal_runtime_disabled )
    ; ( "current_task_id", string_opt_json receipt.current_task_id )
    ; "outcome", `String (outcome_kind_to_tla_receipt receipt.outcome)
    ; "terminal_reason_code", `String terminal_reason_code
    ; "operator_disposition", `String operator_disposition
    ; "operator_disposition_reason", `String operator_disposition_reason
    ; "runtime_contract", runtime_contract
    ; "action_radius", action_radius
    ; "response_text_present", `Bool receipt.response_text_present
    ; "model_used", `Null
    ; ( "completion_contract_result"
      , `String (completion_contract_result_to_string receipt.completion_contract_result) )
    ; ( "actionable_signal"
      , match receipt.actionable_signal with
        | Some signal -> `String (Keeper_contract_classifier.actionable_signal_label signal)
        | None -> `Null )
    ; ( "tool_surface"
      , `Assoc
          [ ( "turn_lane"
            , Keeper_agent_tool_surface.turn_lane_to_yojson receipt.tool_surface.turn_lane
            )
          ] )
    ; ( "sandbox"
      , `Assoc
          [ "kind", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string receipt.sandbox_kind)
          ; ( "sandbox_root", string_opt_json receipt.sandbox_root )
          ; ( "network_mode"
            , `String (Keeper_types_profile_sandbox.network_mode_to_string receipt.network_mode) )
          ] )
    ; ( "runtime"
      , `Assoc
          [ "name", `String (receipt.runtime_id)
          ; "selected_model", string_opt_json receipt.runtime_selected_model
          ; "attempt_count", `Int receipt.runtime_attempt_count
          ; "fallback_applied", `Bool receipt.runtime_fallback_applied
          ; "outcome", `String (runtime_outcome_to_string receipt.runtime_outcome)
          ; "oas_internal_runtime_allowed", `Bool receipt.oas_internal_runtime_allowed
          ; "degraded_retry_applied", `Bool receipt.degraded_retry_applied
          ; ( "degraded_retry_runtime"
            , match receipt.degraded_retry_runtime with
              | Some value -> `String (value)
              | None -> `Null )
          ; ( "fallback_reason"
            , match receipt.fallback_reason with
              | Some value ->
                `String (Keeper_error_classify.degraded_retry_reason_to_string value)
              | None -> `Null )
          ; ( "rotation_attempts"
            , `List
                (List.map
                   runtime_rotation_attempt_to_json
                   receipt.runtime_rotation_attempts) )
          ] )
    ; ( "stop_reason"
      , match receipt.stop_reason with
        | Some value -> `String (stop_reason_to_string value)
        | None -> `Null )
    ; "error", error_json
    ; "started_at", `String receipt.started_at
    ; "ended_at", `String receipt.ended_at
    ; ( "extra_system_context_digest"
      , string_opt_json receipt.extra_system_context_digest )
    ; ( "extra_system_context_injected_size"
      , Json_util.int_opt_to_json receipt.extra_system_context_injected_size )
    ; ( "extra_system_context_computed_size"
      , Json_util.int_opt_to_json receipt.extra_system_context_computed_size )
    ; ( "pre_dispatch_compacted", `Bool receipt.pre_dispatch_compacted )
    ; ( "pre_dispatch_compaction_trigger"
      , string_opt_json receipt.pre_dispatch_compaction_trigger )
    ; ( "pre_dispatch_compaction_before_tokens"
      , Json_util.int_opt_to_json receipt.pre_dispatch_compaction_before_tokens )
    ; ( "pre_dispatch_compaction_after_tokens"
      , Json_util.int_opt_to_json receipt.pre_dispatch_compaction_after_tokens )
    ]
;;

let to_json receipt =
  let disposition, disposition_reason = operator_disposition receipt in
  to_json_with_operator_disposition receipt ~disposition ~disposition_reason
;;

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
     Unknown runtime state      -> [needs_operator_broadcast]
                                  returns [true] for "unknown".
     OperatorBroadcast event    -> [append] emits
                                  "keeper.operator_broadcast_required.v1"
                                  with structured payload.
     Eventually-emit liveness   -> [append] calls the emit when
                                  [needs_operator_broadcast] is true and
                                  records any failure explicitly.

   Bug model (would be violated if a future refactor dropped the first
   emit for a broadcast-worthy state, or skipped without the suppression
   metric): an OperatorBroadcast path that requires manual operator
   dispatch instead of automatic emit would re-create the original
   #fleet-stall bug.  Sibling anchor in [keeper_supervisor.ml]
   (StaleRunning watchdog + emit_stale_keeper_broadcast) is deferred to
   a separate cycle. *)
let needs_operator_broadcast = function
  | Disp_unknown -> true
  | Disp_pass
  | Disp_fail_open_next_runtime
  | Disp_pass_next_model
  | Disp_user_cancelled
  | Disp_skipped -> false
;;

let reaction_kind_of_operator_disposition = function
  | Disp_pass | Disp_skipped -> Keeper_reaction_ledger.Execution_receipt
  | Disp_fail_open_next_runtime
  | Disp_pass_next_model
  | Disp_user_cancelled
  | Disp_unknown -> Keeper_reaction_ledger.Terminal_reason
;;

module Broadcast_dedupe = struct
  (* Tracks only the last successfully emitted key. A->B->A re-emits by
     design so changed failure identities are not hidden; #22391 owns the
     durable state-backed idempotence model.

     [pending_keys] stays as a list because current call sites are low-volume
     watchdog/operator broadcast paths with one in-flight emit per distinct
     keeper key. Keep membership/removal protected and revisit the structure if
     this helper is reused for high-cardinality streams. *)
  type 'key keeper_slot =
    { mu : Eio.Mutex.t
    ; mutable last_key : 'key option
    ; mutable pending_keys : 'key list
    }

  type 'key t =
    { registry_mu : Eio.Mutex.t
    ; by_keeper : (string, 'key keeper_slot) Hashtbl.t
    ; equal : 'key -> 'key -> bool
    }

  type 'event emit_result =
    | Emitted of 'event
    | Duplicate

  let initial_keeper_capacity = 16

  let create ~equal () =
    { registry_mu = Eio.Mutex.create ()
    ; by_keeper = Hashtbl.create initial_keeper_capacity
    ; equal
    }
  ;;

  let slot t ~keeper_name =
    Eio.Mutex.use_rw ~protect:true t.registry_mu (fun () ->
      match Hashtbl.find_opt t.by_keeper keeper_name with
      | Some slot -> slot
      | None ->
        let slot = { mu = Eio.Mutex.create (); last_key = None; pending_keys = [] } in
        Hashtbl.add t.by_keeper keeper_name slot;
        slot)
  ;;

  let key_seen t previous_key key =
    match previous_key with
    | Some previous_key when t.equal previous_key key -> true
    | _ -> false
  ;;

  let key_pending t pending_keys key =
    List.exists (fun pending_key -> t.equal pending_key key) pending_keys
  ;;

  let remove_pending_key t key pending_keys =
    List.filter (fun pending_key -> not (t.equal pending_key key)) pending_keys
  ;;

  let reserve_emit t slot key =
    Eio.Cancel.protect (fun () ->
      Eio.Mutex.use_rw ~protect:true slot.mu (fun () ->
        if key_seen t slot.last_key key || key_pending t slot.pending_keys key
        then false
        else (
          slot.pending_keys <- key :: slot.pending_keys;
          true)))
  ;;

  let commit_emit t slot key =
    Eio.Cancel.protect (fun () ->
      Eio.Mutex.use_rw ~protect:true slot.mu (fun () ->
        slot.pending_keys <- remove_pending_key t key slot.pending_keys;
        slot.last_key <- Some key))
  ;;

  let cancel_emit t slot key =
    Eio.Cancel.protect (fun () ->
      Eio.Mutex.use_rw ~protect:true slot.mu (fun () ->
        slot.pending_keys <- remove_pending_key t key slot.pending_keys))
  ;;

  let emit_once t ~keeper_name ~key ~emit =
    let slot = slot t ~keeper_name in
    if not (reserve_emit t slot key)
    then Duplicate
    else (
      match emit () with
      | event ->
        commit_emit t slot key;
        Emitted event
      | exception exn ->
        let bt = Printexc.get_raw_backtrace () in
        cancel_emit t slot key;
        Printexc.raise_with_backtrace exn bt)
  ;;

  let reset t =
    (* Testing seam only: callers must quiesce in-flight [emit_once] fibers
       before resetting, otherwise a detached slot may still commit/cancel. *)
    Eio.Mutex.use_rw ~protect:true t.registry_mu (fun () ->
      Hashtbl.reset t.by_keeper)
  ;;
end

let operator_broadcast_payload (receipt : t) ~disposition ~reason =
  let terminal_reason_code = receipt.terminal_reason_code in
  let disposition_s = operator_disposition_kind_to_string disposition in
  let reason_s = operator_disposition_reason_to_string reason in
  `Assoc
    [ "schema", `String "keeper.operator_broadcast_required.v1"
    ; "keeper_name", `String receipt.keeper_name
    ; "agent_name", `String receipt.agent_name
    ; "trace_id", `String receipt.trace_id
    ; "generation", `Int receipt.generation
    ; ( "turn_count", Json_util.int_opt_to_json receipt.turn_count )
    ; "disposition", `String disposition_s
    ; "disposition_reason", `String reason_s
    ; "outcome", `String (outcome_kind_to_tla_receipt receipt.outcome)
    ; "terminal_reason_code", `String terminal_reason_code
    ; ( "current_task_id", string_opt_json receipt.current_task_id )
    ; "response_text_present", `Bool receipt.response_text_present
    ; "runtime_id", `String (receipt.runtime_id)
    ; "runtime_outcome", `String (runtime_outcome_to_string receipt.runtime_outcome)
    ; ( "completion_contract_result"
      , `String (completion_contract_result_to_string receipt.completion_contract_result) )
    ; ( "actionable_signal"
      , match receipt.actionable_signal with
        | Some signal -> `String (Keeper_contract_classifier.actionable_signal_label signal)
        | None -> `Null )
    ; ( "sandbox"
      , `Assoc
          [ "kind", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string receipt.sandbox_kind)
          ; "sandbox_root", string_opt_json receipt.sandbox_root
          ; ( "network_mode"
            , `String (Keeper_types_profile_sandbox.network_mode_to_string receipt.network_mode) )
          ] )
    ; "model_used", `Null
    ; ( "stop_reason"
      , match receipt.stop_reason with
        | Some value -> `String (stop_reason_to_string value)
        | None -> `Null )
    ; ( "error_kind"
      , match receipt.error_kind with
        | Some v -> `String (error_kind_to_string v)
        | None -> `Null )
    ; ( "error_message", string_opt_json receipt.error_message )
    ; "ended_at", `String receipt.ended_at
    ]
;;

let emit_operator_broadcast_event config (receipt : t) ~disposition ~reason =
  let payload = operator_broadcast_payload receipt ~disposition ~reason in
  let event =
    Activity_graph.emit
      config
      ~actor:{ Activity_graph.kind = "agent"; id = receipt.agent_name }
      ~kind:"keeper.operator_broadcast_required"
      ~payload
      ()
  in
  Log.Keeper.warn
    ~keeper_name:receipt.keeper_name
    "%s: operator_broadcast_required emitted disposition=%s reason=%s seq=%d"
    receipt.keeper_name
    (operator_disposition_kind_to_string disposition)
    (operator_disposition_reason_to_string reason)
    event.seq
;;

let emit_operator_broadcast config (receipt : t) ~disposition ~reason =
  emit_operator_broadcast_event config receipt ~disposition ~reason
;;

let append (config : Workspace.config) (receipt : t) =
  let store =
    Keeper_types_support.keeper_execution_receipt_store config receipt.keeper_name
  in
  let disposition, reason = operator_disposition receipt in
  let receipt_json =
    to_json_with_operator_disposition
      receipt
      ~disposition
      ~disposition_reason:reason
  in
  Dated_jsonl.append store receipt_json;
  (try
     Keeper_reaction_ledger.record_execution_receipt_reaction
       config
       ~keeper_name:receipt.keeper_name
       ~trace_id:receipt.trace_id
       ?turn_count:receipt.turn_count
       ~current_task_id:receipt.current_task_id
       ~outcome:(outcome_kind_to_tla_receipt receipt.outcome)
       ~reaction_kind:(reaction_kind_of_operator_disposition disposition)
       ~terminal_reason_code:receipt.terminal_reason_code
       ~receipt_json
       ()
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Keeper.warn
       ~keeper_name:receipt.keeper_name
       "%s: reaction ledger receipt append failed trace_id=%s: %s"
       receipt.keeper_name
       receipt.trace_id
       (Printexc.to_string exn));
  if needs_operator_broadcast disposition
  then (
    let disposition_label = operator_disposition_kind_to_string disposition in
    let reason_label = operator_disposition_reason_to_string reason in
    (try
       emit_operator_broadcast config receipt ~disposition ~reason
     with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        (* fail-closed: log loud, do not silently swallow. The append itself
           has already persisted the receipt; the broadcast failure is its
           own diagnostic that watchdogs/log alerts will pick up. *)
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string ExecutionReceiptFailures)
          ~labels:[ "keeper", receipt.keeper_name; "site", Keeper_execution_receipt_failure_site.(to_label Emit_failed) ]
          ();
        Log.Keeper.error
          ~keeper_name:receipt.keeper_name
          "%s: operator_broadcast_required EMIT FAILED disposition=%s reason=%s exn=%s"
          receipt.keeper_name
          disposition_label
          reason_label
          (Printexc.to_string exn)))
;;

(* Watchdog-driven broadcast (#fleet-stall 2026-04-26 Step 3): emitted by a
   supervisor-side fiber when a Running keeper has not produced a turn for
   longer than the stale threshold. This is the path that catches the
   "KSM=Running but no live turn" failure mode where the heartbeat fiber is
   blocked on a long call and would otherwise never produce a receipt. *)
let stale_kill_class_label = function
  | Keeper_registry.Idle_turn _ -> "idle_turn"
  | Keeper_registry.Mid_turn_no_progress _ -> "mid_turn_no_progress"
  | Keeper_registry.Noop_failure_loop _ -> "noop_failure_loop"
;;

let stale_terminal_reason_code_typed = Keeper_turn_terminal_code.of_failure_reason_option

let stale_broadcast_failure_cohort = function
  | Some _ as reason -> Keeper_registry.failure_reason_cohort_key reason
  | None -> "stale_turn_timeout"
;;

let stale_broadcast_failure_reason_text = function
  | Some reason -> Some (Keeper_registry.failure_reason_to_string reason)
  | None -> None
;;

let stale_broadcast_kill_class = function
  | Some (Keeper_registry.Stale_turn_timeout cls) -> Some (stale_kill_class_label cls)
  | _ -> None
;;

let stale_turn_bucket stale_seconds =
  if stale_seconds < 30.0
  then "stale_turn_lt_30s"
  else if stale_seconds < 60.0
  then "stale_turn_30s_to_60s"
  else if stale_seconds < 300.0
  then "stale_turn_1m_to_5m"
  else if stale_seconds < 600.0
  then "stale_turn_5m_to_10m"
  else if stale_seconds < 1_800.0
  then "stale_turn_10m_to_30m"
  else "stale_turn_ge_30m"
;;

type stale_broadcast_dedupe_key =
  { stale_keeper_name : string
  ; stale_agent_name : string
  ; stale_runtime_id : string
  ; stale_trace_id : string
  ; stale_generation : int
  ; stale_failure_reason_cohort : string
  ; stale_terminal_reason_code : string
  ; stale_kill_class : string option
  ; stale_turn_bucket_key : string
  }

let stale_broadcast_dedupe_key
      ~keeper_name
      ~agent_name
      ~runtime_id
      ~trace_id
      ~generation
      ~failure_reason
      ~stale_seconds
  =
  let failure_reason_cohort = stale_broadcast_failure_cohort failure_reason in
  let terminal_reason_code =
    Keeper_turn_terminal_code.to_wire (stale_terminal_reason_code_typed failure_reason)
  in
  { stale_keeper_name = keeper_name
  ; stale_agent_name = agent_name
  ; stale_runtime_id = runtime_id
  ; stale_trace_id = trace_id
  ; stale_generation = generation
  ; stale_failure_reason_cohort = failure_reason_cohort
  ; stale_terminal_reason_code = terminal_reason_code
  ; stale_kill_class = stale_broadcast_kill_class failure_reason
  ; stale_turn_bucket_key = stale_turn_bucket stale_seconds
  }
;;

let equal_stale_broadcast_dedupe_key a b =
  String.equal a.stale_keeper_name b.stale_keeper_name
  && String.equal a.stale_agent_name b.stale_agent_name
  && String.equal a.stale_runtime_id b.stale_runtime_id
  && String.equal a.stale_trace_id b.stale_trace_id
  && Int.equal a.stale_generation b.stale_generation
  && String.equal a.stale_failure_reason_cohort b.stale_failure_reason_cohort
  && String.equal a.stale_terminal_reason_code b.stale_terminal_reason_code
  && Option.equal String.equal a.stale_kill_class b.stale_kill_class
  && String.equal a.stale_turn_bucket_key b.stale_turn_bucket_key
;;

let stale_broadcast_dedupe =
  Broadcast_dedupe.create ~equal:equal_stale_broadcast_dedupe_key ()
;;

let stale_broadcast_payload
      ~keeper_name
      ~agent_name
      ~runtime_id
      ~trace_id
      ~generation
      ~failure_reason
      ~stale_seconds
      ~last_turn_ts
  =
  let runtime_id_string = runtime_id in
  let failure_reason_text = stale_broadcast_failure_reason_text failure_reason in
  let failure_reason_cohort = stale_broadcast_failure_cohort failure_reason in
  `Assoc
    [ "schema", `String "keeper.operator_broadcast_required.v1"
    ; "keeper_name", `String keeper_name
    ; "agent_name", `String agent_name
    ; "runtime_id", `String runtime_id_string
    ; "trace_id", `String trace_id
    ; "generation", `Int generation
    ; "disposition", `String "stalled"
    ; "disposition_reason", `String failure_reason_cohort
    ; ( "terminal_reason_code"
      , `String
          (Keeper_turn_terminal_code.to_wire
             (stale_terminal_reason_code_typed failure_reason)) )
    ; "failure_reason", string_opt_json failure_reason_text
    ; "failure_reason_cohort", `String failure_reason_cohort
    ; "stale_kill_class", string_opt_json (stale_broadcast_kill_class failure_reason)
    ; "stale_turn_bucket", `String (stale_turn_bucket stale_seconds)
    ; "stale_seconds", `Float stale_seconds
    ; "last_turn_ts", `Float last_turn_ts
    ; "source", `String "watchdog"
    ]
;;

let emit_stale_keeper_broadcast
      config
      ~keeper_name
      ~agent_name
      ~runtime_id
      ~trace_id
      ~generation
      ~failure_reason
      ~stale_seconds
      ~last_turn_ts
  =
  let runtime_id_string = runtime_id in
  let key =
    stale_broadcast_dedupe_key
      ~keeper_name
      ~agent_name
      ~runtime_id
      ~trace_id
      ~generation
      ~failure_reason
      ~stale_seconds
  in
  let payload =
    stale_broadcast_payload
      ~keeper_name
      ~agent_name
      ~runtime_id
      ~trace_id
      ~generation
      ~stale_seconds
      ~last_turn_ts
      ~failure_reason
  in
  let emit_result =
    try
      Ok
        (Broadcast_dedupe.emit_once
           stale_broadcast_dedupe
           ~keeper_name
           ~key
           ~emit:(fun () ->
             Activity_graph.emit
               config
               ~actor:{ Activity_graph.kind = "watchdog"; id = keeper_name }
               ~kind:"keeper.operator_broadcast_required"
               ~payload
               ()))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error exn
  in
  match emit_result with
  | Ok (Broadcast_dedupe.Emitted event) ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ExecutionReceiptFailures)
      ~labels:[ "keeper", keeper_name; "site", Keeper_execution_receipt_failure_site.(to_label Stale_broadcast) ]
      ();
    Log.Keeper.warn
      ~keeper_name
      "%s: stale_keeper_broadcast emitted last_turn=%.0fs ago runtime=%s seq=%d"
      keeper_name
      stale_seconds
      runtime_id_string
      event.seq
  | Ok Broadcast_dedupe.Duplicate ->
    let reason = "stale_keeper_broadcast_duplicate" in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string OperatorBroadcastSuppressed)
      ~labels:[ "keeper", keeper_name; "reason", reason ]
      ();
    Log.Keeper.info
      ~keeper_name
      "%s: stale_keeper_broadcast suppressed duplicate bucket=%s runtime=%s"
      keeper_name
      (stale_turn_bucket stale_seconds)
      runtime_id_string
  | Error exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ExecutionReceiptFailures)
      ~labels:[ "keeper", keeper_name; "site", Keeper_execution_receipt_failure_site.(to_label Emit_failed) ]
      ();
    (* Activity_graph.emit currently raises exceptions rather than returning a
       typed error; Cancelled is re-raised above, and this string is operator
       evidence for the graph emit boundary only. *)
    Log.Keeper.error
      ~keeper_name
      "%s: stale_keeper_broadcast EMIT FAILED bucket=%s runtime=%s exn=%s"
      keeper_name
      (stale_turn_bucket stale_seconds)
      runtime_id_string
      (Printexc.to_string exn)
;;

let latest_json (config : Workspace.config) keeper_name =
  let store = Keeper_types_support.keeper_execution_receipt_store config keeper_name in
  match Dated_jsonl.read_recent store 1 with
  | [ json ] -> Some json
  | _ -> None
;;

let latest_json_by_keeper (config : Workspace.config) keeper_names =
  keeper_names
  |> List.filter_map (fun keeper_name ->
    match latest_json config keeper_name with
    | Some json -> Some (keeper_name, json)
    | None -> None)
;;

module For_testing = struct
  let stale_broadcast_dedupe_key = stale_broadcast_dedupe_key
  let stale_turn_bucket = stale_turn_bucket

  let emit_stale_keeper_broadcast_dedupe_for_testing
        ~keeper_name
        ~agent_name
        ~runtime_id
        ~trace_id
        ~generation
        ~failure_reason
        ~stale_seconds
        ~emit
    =
    let key =
      stale_broadcast_dedupe_key
        ~keeper_name
        ~agent_name
        ~runtime_id
        ~trace_id
        ~generation
        ~failure_reason
        ~stale_seconds
    in
    match Broadcast_dedupe.emit_once stale_broadcast_dedupe ~keeper_name ~key ~emit with
    | Broadcast_dedupe.Emitted () -> true
    | Broadcast_dedupe.Duplicate -> false
  ;;

  let reset_stale_broadcast_dedupe () =
    Broadcast_dedupe.reset stale_broadcast_dedupe
  ;;
end
