(** Keeper_rollover — OAS handoff rollover logic.

    When a keeper's context ratio exceeds the handoff threshold and
    cooldown has elapsed, creates a new session with the current context
    carried forward to the next generation.

    Extracted from Keeper_context_runtime as part of #4955 god-file split.

    Spec navigation (OCaml -> TLA+) — plan §19 anchor pattern.
    Authoritative spec mirror is
    [specs/keeper-state-machine/KeeperGenerationLineage.tla].

    Spec lines 10-13 already cite this module:
    "Modeled from: lib/keeper/keeper_post_turn.ml, lib/keeper/keeper_rollover.ml,
    lib/keeper_types/keeper_types.mli".  This block is the reverse-direction
    citation so code search for "KeeperGenerationLineage" lands here.

    Spec semantics modelled (TLA+ -> OCaml):
      keeper_phase                 [meta] phase as observed during
                                   handoff (idle / running / handing_off).
      generation                   [meta.generation] field — incremented
                                   on every successful rollover here.
      current_trace_id             new trace allocated by the rollover
                                   path; replaces the previous trace on
                                   successful handoff.
      trace_history                append-only ancestry recorded into
                                   meta when rollover commits.
      ckpt_valid / ckpt_generation [Keeper_types]'s checkpoint lineage
                                   parity that the handoff must preserve.

    Spec scope (line 4-8):
      - same keeper identity across generations
      - trace_id replacement on successful handoff
      - trace_history append-only ancestry
      - checkpoint lineage parity once the keeper returns to idle

    Out of scope (line 15-18):
      - compaction strategy selection (KeeperCompactionLifecycle)
      - tool execution / Agent.run turn loop
      - long-term memory recall semantics

    The spec models "same keeper, new trace" rather than a new child
    runtime — this is the generation contract the rollover enforces. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_core

let log_tool_pair_repair
    ~keeper_name
    ~site
    (stats : Keeper_context_core.tool_pair_repair_stats) =
  if Keeper_context_core.tool_pair_repair_stats_changed stats then
    Log.Harness.emit
      Log.Warn
      ~details:
        (`Assoc
            [ "keeper_name", `String keeper_name
            ; "site", `String site
            ; "dropped_tool_uses", `Int stats.dropped_tool_uses
            ; "dropped_tool_results", `Int stats.dropped_tool_results
            ; ( "dropped_tool_use_samples"
              , `List
                  (List.map
                     (fun (tool_use_id, tool_name) ->
                        `Assoc
                          [ "tool_use_id", `String tool_use_id
                          ; "tool_name", `String tool_name
                          ])
                     stats.dropped_tool_use_samples) )
            ; ( "dropped_tool_result_ids"
              , `List
                  (List.map
                     (fun tool_use_id -> `String tool_use_id)
                     stats.dropped_tool_result_ids) )
            ])
      (Printf.sprintf
         "tool_pair_repair keeper=%s site=%s dropped_tool_uses=%d \
          dropped_tool_results=%d"
         keeper_name
         site
         stats.dropped_tool_uses
         stats.dropped_tool_results)

type handoff_rollover = {
  updated_meta : keeper_meta;
  handoff_json : Yojson.Safe.t option;
  attempted : bool;
  failure_reason : string option;
  context_ratio : float;
  context_tokens : int;
  context_max : int;
  message_count : int;
}

(** [blocker_class_indicates_overflow klass] returns true when [klass] is the
    typed equivalent of a provider context-overflow signal.

    Provider/model are treated as opaque aliases at the keeper layer: the
    SDK boundary ([Keeper_status_bridge.blocker_class_of_sdk_error]) is the
    only place where structured SDK errors are classified. Once the boundary
    has classified the error, downstream consumers (rollover, dashboard,
    supervisor) reason only over the typed [blocker_class] — never
    substring-matching the [detail] field. *)
let blocker_class_indicates_overflow (klass : blocker_class) : bool =
  match klass with
  | Sdk_token_budget_exceeded -> true
  | Runtime_exhausted _
  | Capacity_backpressure
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure
  | Oas_agent_execution_timeout
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Turn_timeout
  | Turn_livelock_blocked
  | Completion_contract_violation
  | No_progress_loop
  | Fiber_unresolved
  | Stale_turn_timeout
  | Stale_fleet_batch
  | Sdk_max_turns_exceeded
  | Sdk_cost_budget_exceeded
  | Sdk_unrecognized_stop_reason
  | Sdk_idle_detected
  | Sdk_guardrail_violation
  | Sdk_tripwire_violation
  | Sdk_exit_condition_met
  | Sdk_input_required
  | Sdk_tool_failure_recovery_failed -> false

type rollover_gate_decision =
  | Skip of string
  | Go of string

let append_lineage_artifacts_best_effort
    ~(config : Workspace.config)
    ~(parent : keeper_meta)
    ~(child : keeper_meta)
    ~(parent_trace_id : string)
    ~(trigger_reason : string)
    ~(context_ratio : float) =
  try
    Keeper_generation_lineage.record_handoff_artifacts
      ~config
      ~parent
      ~child
      ~parent_trace_id
      ~trigger_reason
      ~context_ratio
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string RolloverFailures)
        ~labels:[("keeper", child.name); ("site", "lineage_append")]
        ();
      Log.Keeper.warn ~keeper_name:child.name
        "lineage append skipped after rollover trace=%s->%s: %s"
        parent_trace_id
        (Keeper_id.Trace_id.to_string child.runtime.trace_id)
        (Printexc.to_string exn)

(** [classify_rollover_gate] returns the gate verdict without any side effects.

    The ratio gate reflects the *checkpoint* history. The signal gate reflects
    the *actual* LLM response for the last turn: when a proactive turn errored
    with an overflow-class blocker, rollover is triggered regardless of the
    checkpoint ratio — the ratio gate structurally cannot fire once compaction
    shrinks the checkpoint below the threshold (umbrella #7036).

    Spec mirror: [specs/keeper-state-machine/KeeperRolloverDecision.tla] models
    this gate (vars autoHandoff / cooldownElapsed / ratioGate / lastOutcome /
    blockerClass / decision); [SignalGateOverflowOnly] is the safety invariant
    that the signal half fires only on an overflow-class blocker, and the
    bug-model cfg checks that the historical "any non-empty class" substring
    drift would violate it.  The spec models the [last_blocker_info] +
    [Proactive_error] disjunct only; the [?current_turn_blocker_info] disjunct
    uses the same typed [blocker_class_indicates_overflow] predicate so it is
    covered by construction.  Reverse-citation so code search for
    "KeeperRolloverDecision" lands here. *)
let classify_rollover_gate
    ~(auto_handoff : bool) ~(cooldown_elapsed : bool)
    ~(ratio : float) ~(handoff_threshold : float)
    ~(last_outcome : proactive_cycle_outcome)
    ~(last_blocker_info : blocker_info option)
    ?(current_turn_blocker_info : blocker_info option = None)
    () : rollover_gate_decision =
  if not auto_handoff then Skip "auto_handoff_disabled"
  else if not cooldown_elapsed then Skip "cooldown"
  else
    let ratio_gate = ratio >= handoff_threshold in
    let info_indicates_overflow = function
      | Some { klass; _ } -> blocker_class_indicates_overflow klass
      | None -> false
    in
    let current_turn_signal = info_indicates_overflow current_turn_blocker_info in
    let signal_gate =
      current_turn_signal
      || (last_outcome = Proactive_error
          && info_indicates_overflow last_blocker_info)
    in
    match ratio_gate, signal_gate with
    | true, true -> Go "ratio+signal"
    | false, true -> Go "persistent_overflow_blocker"
    | true, false -> Go "ratio"
    | false, false -> Skip "below_thresholds"

let maybe_rollover_oas_handoff
    ~(on_started : unit -> unit)
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(model : string)
    ~(primary_model_max_tokens : int)
    ~(current_turn_blocker_info : blocker_info option)
    ~(checkpoint : Agent_sdk.Checkpoint.t option) : handoff_rollover =
  match checkpoint with
  | None ->
      {
        updated_meta = meta;
        handoff_json = None;
        attempted = false;
        failure_reason = None;
        context_ratio = 0.0;
        context_tokens = 0;
        context_max = primary_model_max_tokens;
        message_count = 0;
      }
  | Some cp ->
      let ctx =
        context_of_oas_checkpoint
          ~repair_orphans:false
          ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
          cp
          ~primary_model_max_tokens
      in
      let current_generation =
        checkpoint_generation cp ~fallback:meta.runtime.generation
      in
      let base_meta =
        if current_generation = meta.runtime.generation then meta
        else map_runtime (fun rt -> { rt with generation = current_generation }) meta
      in
      let ratio = context_ratio ctx in
      let cooldown_elapsed =
        base_meta.runtime.last_handoff_ts <= 0.0
        || Time_compat.now () -. base_meta.runtime.last_handoff_ts
           >= float_of_int base_meta.handoff_cooldown_sec
      in
      let gate_decision =
        classify_rollover_gate
          ~auto_handoff:base_meta.auto_handoff
          ~cooldown_elapsed
          ~ratio
          ~handoff_threshold:base_meta.handoff_threshold
          ~last_outcome:base_meta.runtime.proactive_rt.last_outcome
          ~last_blocker_info:base_meta.runtime.last_blocker
          ~current_turn_blocker_info
          ()
      in
      let rollover_base =
        {
          updated_meta = base_meta;
          handoff_json = None;
          attempted = false;
          failure_reason = None;
          context_ratio = ratio;
          context_tokens = token_count ctx;
          context_max = max_tokens_of_context ctx;
          message_count = message_count ctx;
        }
      in
      (match gate_decision with
      | Skip _ -> rollover_base
      | Go trigger_reason ->
        let now_ts = Time_compat.now () in
        let prev_trace_id = base_meta.runtime.trace_id in
        let new_trace_id = Keeper_identity.generate_trace_id () in
        let next_generation = current_generation + 1 in
        (* PR-J: see keeper_post_turn.ml for the rationale on
           keep-going-on-callback-failure. The handoff path mirrors
           the compaction path so the operator counter aggregates a
           single fleet-wide invariant: any lifecycle callback that
           can't reach the registry must surface as a counter+warn and
           durable telemetry gap, never silently abort the rollover. *)
        let () =
          Cancel_safe.observe
            ~on_exn:(fun exn ->
              Otel_metric_store.inc_counter Keeper_metrics.(to_string LifecycleCallbackFailures)
                ~labels:[ ("keeper", base_meta.name); ("callback", "on_handoff_started") ] ();
              Keeper_callback_failure.record ~base_dir ~meta:base_meta
                ~callback:"on_handoff_started" exn)
            on_started
        in
        (try
          let new_session =
            create_session ~session_id:new_trace_id ~base_dir
          in
          let save_ctx =
            let messages, pair_repair_stats =
              repair_broken_tool_call_pairs_with_stats
                (messages_of_context ctx)
            in
            log_tool_pair_repair
              ~keeper_name:base_meta.agent_name
              ~site:"handoff_rollover"
              pair_repair_stats;
            {
              ctx with
              checkpoint =
                {
                  (checkpoint_of_context ctx) with
                  messages;
                };
            }
          in
          match save_oas_checkpoint
                  ~max_checkpoint_messages:base_meta.compaction.max_checkpoint_messages
                  ~multimodal_policy:base_meta.multimodal_policy
                  ~keeper_name:base_meta.name
                  ~session:new_session
                  ~agent_name:base_meta.agent_name
                  ~ctx:save_ctx ~generation:next_generation with
          | Error e ->
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string CheckpointFailures)
                ~labels:[("keeper", base_meta.name); ("site", "rollover_handoff_save")]
                ();
              Log.Keeper.error ~keeper_name:base_meta.name
                "OAS handoff rollover ABORTED — checkpoint save failed: %s"
                e;
              { rollover_base with attempted = true; failure_reason = Some e }
          | Ok _checkpoint ->
              (match Keeper_id.Trace_id.of_string new_trace_id with
               | Error err ->
                 Otel_metric_store.inc_counter
                   Keeper_metrics.(to_string RolloverFailures)
                   ~labels:[("keeper", base_meta.name); ("site", "invalid_trace_id")]
                   ();
                 Log.Keeper.error ~keeper_name:base_meta.name
                   "OAS handoff rollover ABORTED — generated invalid trace_id %s: %s"
                   new_trace_id err;
                 { rollover_base with
                   attempted = true;
                   failure_reason = Some err;
                 }
               | Ok parsed_trace_id ->
                 let updated_meta =
                   {
                     base_meta with
                     updated_at = now_iso ();
                     runtime = { base_meta.runtime with
                       trace_id = parsed_trace_id;
                       trace_history =
                         dedupe_keep_order ((Keeper_id.Trace_id.to_string prev_trace_id) :: base_meta.runtime.trace_history);
                       generation = next_generation;
                       last_handoff_ts = now_ts;
                     };
                   }
                 in
                 (* RFC-0132 PR-2: handoff event surface = external boundary; redact via SSOT. *)
                 let model =
                   Boundary_redaction.to_string
                     Boundary_redaction.runtime_model_label
                 in
                 let handoff_json =
                   `Assoc
                     [
                       ("performed", `Bool true);
                       ("from_generation", `Int current_generation);
                       ("to_generation", `Int next_generation);
                       ("new_generation", `Int next_generation);
                       ("prev_trace_id", `String (Keeper_id.Trace_id.to_string prev_trace_id));
                       ("new_trace_id", `String new_trace_id);
                       ("to_model", `String model);
                       ("context_ratio", `Float ratio);
                       ("trigger_reason", `String trigger_reason);
                     ]
                 in
                 Log.Keeper.info ~keeper_name:base_meta.name
                   "OAS handoff rollover trace=%s->%s gen=%d->%d ratio=%.3f trigger=%s"
                   (Keeper_id.Trace_id.to_string prev_trace_id) new_trace_id current_generation
                   next_generation ratio trigger_reason;
                 (* OAS owns checkpoint/session continuity.
                    MASC lineage telemetry is append-only best-effort data and
                    must never roll back a successful rollover. *)
                 let lineage_config =
                   Workspace.default_config (Filename.dirname (Filename.dirname base_dir))
                 in
                 append_lineage_artifacts_best_effort
                   ~config:lineage_config
                   ~parent:base_meta
                   ~child:updated_meta
                   ~parent_trace_id:(Keeper_id.Trace_id.to_string prev_trace_id)
                   ~trigger_reason
                   ~context_ratio:ratio;
                 { rollover_base with
                   updated_meta;
                   handoff_json = Some handoff_json;
                   attempted = true;
                   failure_reason = None;
                 })
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            log_keeper_exn ~label:"keeper OAS handoff rollover failed" exn;
            { rollover_base with
              attempted = true;
              failure_reason = Some (Printexc.to_string exn);
            }))
