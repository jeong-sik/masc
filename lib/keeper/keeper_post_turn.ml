(** Keeper_post_turn — post-turn lifecycle: compaction, handoff rollover,
    continuity summary, and overflow retry recovery.

    Orchestrates the end-of-turn pipeline that decides whether to compact
    the context, roll over to a new generation, and update the continuity
    summary from the latest state snapshot.

    This module owns only the checkpoint/lineage tail of a keeper turn.
    Memory bank append, episode flush, and Hebbian learning are recorded
    elsewhere:
    - memory bank / episodes: [Keeper_agent_run] tail after [Agent.run]
    - hebbian: task lifecycle in [Coord_task]

    Extracted from Keeper_exec_context as part of #4955 god-file split.

    Spec navigation (OCaml -> TLA+) — plan §19 anchor pattern.  Sibling
    to #11612 (Cycle 31, [keeper_rollover.ml]).  Authoritative spec
    mirror is [specs/keeper-state-machine/KeeperGenerationLineage.tla].

    Spec lines 10-13 already cite this module as one of three modeled
    OCaml sources:
      - lib/keeper/keeper_post_turn.ml   (this file — post-turn pipeline)
      - lib/keeper/keeper_rollover.ml    (rollover semantics — anchored
                                          in #11612)
      - lib/keeper/keeper_types.mli      (type lineage — anchor deferred)

    This block is the reverse-direction citation so code search for
    "KeeperGenerationLineage" lands here.

    Post-turn -> spec mapping:
      Compaction phase    feeds into [keeper_phase] = "running" while
                          the in-flight turn is still resolving.
      Handoff rollover    delegates to [Keeper_rollover.attempt] and
                          increments [meta.generation] — spec's
                          generation variable.  The new trace_id and
                          trace_history append happen there.
      Continuity summary  refreshes the [meta.continuity_summary] /
                          checkpoint pair after rollover, preserving
                          the spec's [ckpt_valid] / [ckpt_generation]
                          parity invariant.

    Spec scope (line 4-8): same identity across generations,
    trace_id replacement, append-only ancestry, checkpoint lineage
    parity once back to idle.

    Spec out-of-scope (line 15-18 in spec): compaction strategy
    selection (KeeperCompactionLifecycle), Agent.run turn loop,
    long-term memory recall.  This module *triggers* compaction but
    does not *select* the strategy. *)

open Keeper_types
open Keeper_memory
open Keeper_context_core

type compaction_event = {
  attempted : bool;
  applied : bool;
  failure_reason : string option;
  trigger : string option;
  decision : Keeper_compact_policy.compaction_decision;
  before_tokens : int;
  after_tokens : int;
  saved_tokens : int;
}

type post_turn_lifecycle = {
  updated_meta : keeper_meta;
  checkpoint : Agent_sdk.Checkpoint.t option;
  handoff_json : Yojson.Safe.t option;
  handoff_attempted : bool;
  handoff_failure_reason : string option;
  compaction : compaction_event;
  turn_generation : int;
  context_ratio : float;
  context_tokens : int;
  context_max : int;
  message_count : int;
}

type overflow_retry_recovery = {
  checkpoint : Agent_sdk.Checkpoint.t;
  compaction : compaction_event;
  turn_generation : int;
} [@@warning "-69"]

(* ── Tier A5: autonomous post-turn wire-in (Cycle 22) ──────────────
   Feature-flag-gated, non-invasive layer. When [MASC_AUTONOMOUS] is
   off (default), this is a pure pass-through — zero impact on the
   existing post-turn lifecycle. When on, an [Autonomous_bridge] tick
   is taken at the tail and the suspended state is upserted into
   [working_context["autonomous_meta"]] of the OAS Checkpoint.

   Failures inside the wire-in (resume parse error, tick exception)
   do not propagate — they are logged and the unmodified lifecycle
   result is returned, preserving the keeper's primary turn outcome. *)

(* The two pure helpers ([masc_autonomous_enabled] / [upsert_autonomous_meta])
   live in [lib/autonomous/wirein_helpers.{mli,ml}] so unit tests can
   call them without depending on the full [masc_mcp] library. The
   wire-in below dispatches through [Autonomous.Wirein_helpers]. *)

let bridge_after_tick (bridge : Autonomous.Autonomous_bridge.t) ~now :
    Autonomous.Autonomous_bridge.t =
  match Autonomous.Autonomous_bridge.tick bridge ~now with
  | Shared_types.Resilience_outcome.FullSuccess { value; _ } -> value
  | Shared_types.Resilience_outcome.PartialSuccess { value; _ } -> value
  | Shared_types.Resilience_outcome.GracefulFailure _ -> bridge

let apply_autonomous_wirein
    ~(now : float)
    (lifecycle : post_turn_lifecycle) : post_turn_lifecycle =
  if not (Autonomous.Wirein_helpers.masc_autonomous_enabled ()) then lifecycle
  else
    match lifecycle.checkpoint with
    | None ->
        (* No checkpoint to enrich; autonomous_meta has no host. *)
        lifecycle
    | Some cp -> (
        try
          let prev_meta_opt =
            match cp.Agent_sdk.Checkpoint.working_context with
            | Some (`Assoc kv) -> List.assoc_opt "autonomous_meta" kv
            | _ -> None
          in
          let witness =
            Autonomous.Autonomous_bridge.Witness.running_witness
          in
          let bridge =
            match prev_meta_opt with
            | Some prev_json -> (
                match
                  Autonomous.Autonomous_bridge.resume witness prev_json ~now
                with
                | Ok b -> b
                | Error _ ->
                    Autonomous.Autonomous_bridge.create witness ~now ())
            | None -> Autonomous.Autonomous_bridge.create witness ~now ()
          in
          let bridge' = bridge_after_tick bridge ~now in
          let suspended = Autonomous.Autonomous_bridge.suspend bridge' in
          let new_wc =
            Autonomous.Wirein_helpers.upsert_autonomous_meta
              cp.Agent_sdk.Checkpoint.working_context suspended
          in
          let new_cp =
            { cp with Agent_sdk.Checkpoint.working_context = new_wc }
          in
          { lifecycle with checkpoint = Some new_cp }
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.warn
            "keeper:%s autonomous wire-in failed: %s"
            lifecycle.updated_meta.name (Printexc.to_string exn);
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_post_turn_wirein_failures
            ~labels:[("keeper", lifecycle.updated_meta.name); ("phase", "autonomous")]
            ();
          lifecycle)

(* ── Tier A6: resilience post-turn wire-in (Cycle 23) ──────────────
   Feature-flag-gated layer that runs IMMEDIATELY AFTER the A5
   autonomous wire-in. The strict ordering [autonomous → resilience]
   is hard-coded at the call site below — do not reorder.

   When [MASC_RESILIENCE] is off (default), this is a pure pass-
   through. When on, [Recovery.classify_string] runs against any
   error signal surfaced by the turn's compaction or handoff steps,
   and a [`Assoc] meta tree is upserted into
   [working_context["resilience_meta"]] alongside any A5
   ["autonomous_meta"] entry.

   Failures inside the wire-in do not propagate — they are logged
   and the unmodified lifecycle result is returned, preserving the
   keeper's primary turn outcome. *)

let apply_resilience_wirein
    ?audit_store
    ?strategy_executor
    ~(now : float)
    (lifecycle : post_turn_lifecycle) : post_turn_lifecycle =
  if not (Resilience.Keeper_bridge.masc_resilience_enabled ()) then lifecycle
  else
    match lifecycle.checkpoint with
    | None ->
        (* No checkpoint to enrich; resilience_meta has no host. *)
        lifecycle
    | Some cp -> (
        try
          let maybe_error =
            (* First non-None error signal from this turn's
               compaction or handoff steps. *)
            match lifecycle.compaction.failure_reason with
            | Some _ as r -> r
            | None -> lifecycle.handoff_failure_reason
          in
          let witness = Resilience.Keeper_bridge.running_witness in
          let outcome =
            Resilience.Keeper_bridge.apply_post_turn_resilience
              witness ?audit_store ?strategy_executor ~now
              ~working_context:cp.Agent_sdk.Checkpoint.working_context
              ~maybe_error ()
          in
          let new_cp =
            { cp with
              Agent_sdk.Checkpoint.working_context = outcome.working_context
            }
          in
          { lifecycle with checkpoint = Some new_cp }
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.warn
            "keeper:%s resilience wire-in failed: %s"
            lifecycle.updated_meta.name (Printexc.to_string exn);
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_post_turn_wirein_failures
            ~labels:[("keeper", lifecycle.updated_meta.name); ("phase", "resilience")]
            ();
          lifecycle)

(* ── Tier K1: multimodal post-turn wire-in (Cycle 27) ─────────────
   Feature-flag-gated wire-in that runs after the A5/A6 pair. Reads
   raw multimodal artifacts the keeper agent dropped into
   [working_context["multimodal_artifacts"]], hydrates them via
   [Multimodal_keeper_bridge.hydrate_one], and accumulates them into
   the process-wide [Multimodal.Workspace_holder].

   When [MASC_MULTIMODAL] is off (default), the wire-in is a pure
   pass-through. When on, it consumes the artifact bag and replaces
   it with a [workspace_meta] summary so the next turn does not
   re-process the same entries.

   Failures inside the wire-in do not propagate — they are logged
   and the unmodified lifecycle result is returned, preserving the
   keeper's primary turn outcome. *)

(* ── Tier K4b: tool-emission drain (Cycle 27) ──────────────────────
   Drains the K4 hook accumulator (parsed JSONs captured by
   [Keeper_tool_emission_hook.make_post_tool_use_hook] during
   Agent.run) into [working_context["multimodal_artifacts"]] so the
   K1 wirein below picks them up.

   Strict ordering: this MUST run BEFORE [apply_multimodal_wirein].
   K4b emit + K1 hydrate is a producer/consumer pair on the same
   working_context bag.

   Feature flag: [MASC_TOOL_EMISSION] (default off). When off, the
   drain is a no-op (the hook itself is also a no-op when the flag
   is off, so the accumulator is empty). *)
let apply_tool_emission_wirein
    ~(now : float)
    (lifecycle : post_turn_lifecycle) : post_turn_lifecycle =
  let _ = now in
  if not (Keeper_tool_emission_hook.masc_tool_emission_enabled ()) then
    lifecycle
  else
    match lifecycle.checkpoint with
    | None -> lifecycle
    | Some cp -> (
        try
          let acc =
            (* Tier K4c — pull THIS keeper's accumulator. Producer
               side ([Keeper_run_tools]) registered it under the
               same name pre-Agent.run, so the items captured during
               this turn drain into this turn's working_context. *)
            Keeper_tool_emission_hook.accumulator_for_keeper
              lifecycle.updated_meta.name
          in
          let new_wc =
            Keeper_tool_emission_hook.drain_into_working_context
              acc
              ~working_context:cp.Agent_sdk.Checkpoint.working_context
          in
          let new_cp =
            { cp with Agent_sdk.Checkpoint.working_context = new_wc }
          in
          { lifecycle with checkpoint = Some new_cp }
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.warn
            "keeper:%s tool emission drain failed: %s"
            lifecycle.updated_meta.name
            (Printexc.to_string exn);
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_post_turn_wirein_failures
            ~labels:[("keeper", lifecycle.updated_meta.name); ("phase", "tool_emission_drain")]
            ();
          lifecycle)

let apply_multimodal_wirein
    ~(now : float)
    (lifecycle : post_turn_lifecycle) : post_turn_lifecycle =
  if not (Multimodal.Wirein_helpers.masc_multimodal_enabled ()) then
    lifecycle
  else
    match lifecycle.checkpoint with
    | None -> lifecycle
    | Some cp -> (
        try
          let raws, wc_rest =
            Multimodal.Wirein_helpers.extract_raw_artifacts
              cp.Agent_sdk.Checkpoint.working_context
          in
          let added_count = ref 0 in
          let last_id = ref None in
          Multimodal.Workspace_holder.update (fun ws ->
              let ws', added =
                Multimodal.Multimodal_keeper_bridge
                .hydrate_with_workspace ws raws
                  ~now
                  ~created_by:lifecycle.updated_meta.name
              in
              added_count := List.length added;
              (match List.rev added with
               | [] -> ()
               | last :: _ ->
                   last_id :=
                     Some
                       (Shared_types.Artifact_id.to_string
                          (Multimodal.Artifact.any_id last)));
              ws')
          ;
          let workspace_size =
            Multimodal.Workspace.size
              (Multimodal.Workspace_holder.get ())
          in
          let meta =
            `Assoc
              [
                ("added_this_turn", `Int !added_count);
                ("workspace_size", `Int workspace_size);
                ( "last_artifact_id",
                  match !last_id with
                  | Some s -> `String s
                  | None -> `Null );
                ("at", `Float now);
              ]
          in
          let new_wc =
            Multimodal.Wirein_helpers.upsert_workspace_meta wc_rest
              meta
          in
          let new_cp =
            { cp with Agent_sdk.Checkpoint.working_context = new_wc }
          in
          { lifecycle with checkpoint = Some new_cp }
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.warn
            "keeper:%s multimodal wire-in failed: %s"
            lifecycle.updated_meta.name (Printexc.to_string exn);
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_post_turn_wirein_failures
            ~labels:[("keeper", lifecycle.updated_meta.name); ("phase", "multimodal")]
            ();
          lifecycle)

let apply_post_turn_lifecycle_with_resilience_handles
    ~(resilience_audit_store : Shared_audit.Store.t option)
    ~(resilience_strategy_executor : Resilience.Recovery.strategy_executor option)
    ~(on_compaction_started : unit -> unit)
    ~(on_handoff_started : unit -> unit)
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(model : string)
    ~(primary_model_max_tokens : int)
    ~(current_turn_overflow_blocker : string option)
    ~(checkpoint : Agent_sdk.Checkpoint.t option) : post_turn_lifecycle =
  (* Reviewer #13214: an executor without an audit store would let
     retry/fallback/handoff/abort callbacks mutate live state
     without the pre-flight RecoveryAttempted envelope that
     keeper_bridge relies on for durable auditability.  Reject the
     combination at the seam so the invariant fails fast at the
     call site, not later when an envelope is missing. *)
  (match resilience_audit_store, resilience_strategy_executor with
   | None, Some _ ->
     invalid_arg
       "Keeper_post_turn.apply_post_turn_lifecycle_with_resilience_handles: \
        resilience_strategy_executor requires resilience_audit_store; \
        executor without audit store would skip the RecoveryAttempted \
        envelope and break durable auditability"
   | _ -> ());
  let now_ts = Time_compat.now () in
  let no_checkpoint_decision = Keeper_compact_policy.Skipped_no_checkpoint in
  let apply_continuity_summary
      ~(meta : keeper_meta)
      ~(ctx : working_context)
      ~(oas_checkpoint : Agent_sdk.Checkpoint.t option) : keeper_meta =
    let progress_path =
      Filename.concat
        (Filename.concat (Filename.concat (Filename.dirname base_dir) "keepers") meta.name)
        "progress.md"
    in
    let structured_snapshot =
      match oas_checkpoint with
      | Some cp -> (
          match cp.Agent_sdk.Checkpoint.working_context with
          | Some json ->
              Keeper_memory_policy.snapshot_of_structured_working_context json
          | None -> None)
      | None -> None
    in
    let snapshot =
      match latest_state_snapshot_from_messages (messages_of_context ctx) with
      | Some _ as snapshot -> snapshot
      | None -> structured_snapshot
    in
    match snapshot with
    | None -> meta
    | Some snapshot ->
        (* Gen7: cap snapshot size before rendering + persisting.
           Bounds string prose and list items so meta.continuity_summary
           cannot grow unboundedly even when the LLM produces a longer
           [STATE] block each turn. *)
        let snapshot = Keeper_memory_policy.cap_snapshot snapshot in
        let progress_snapshot =
          Keeper_memory_policy.forward_looking_snapshot snapshot
        in
        (match
           Keeper_memory_policy.write_progress_snapshot_path
             ~path:progress_path
             ~generation:meta.runtime.generation
             ~updated_at:(now_iso ())
             progress_snapshot
         with
         | Ok () -> ()
         | Error err ->
             Log.Keeper.warn
               "keeper:%s progress snapshot write failed: %s"
               meta.name err;
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_snapshot_write_failures
               ~labels:[("keeper", meta.name)]
               ());
        {
          meta with
          continuity_summary = keeper_state_snapshot_to_summary_text snapshot;
          runtime =
            {
              meta.runtime with
              last_continuity_update_ts = now_ts;
            };
        }
  in
  let body = match checkpoint with
  | None ->
      let updated_meta =
        map_runtime
          (fun rt ->
            {
              rt with
              compaction_rt =
                {
                  rt.compaction_rt with
                  last_check_ts = now_ts;
                  last_decision =
                    Keeper_compact_policy.compaction_decision_to_string
                      no_checkpoint_decision
                    |> compaction_runtime_decision_of_string;
                };
            })
          meta
      in
      {
        updated_meta;
        checkpoint = None;
        handoff_json = None;
        handoff_attempted = false;
        handoff_failure_reason = None;
        compaction =
          {
            attempted = false;
            applied = false;
            failure_reason = None;
            trigger = None;
            decision = no_checkpoint_decision;
            before_tokens = 0;
            after_tokens = 0;
            saved_tokens = 0;
          };
        turn_generation = meta.runtime.generation;
        context_ratio = 0.0;
        context_tokens = 0;
        context_max = primary_model_max_tokens;
        message_count = 0;
      }
  | Some cp ->
      let ctx =
        context_of_oas_checkpoint
          ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
          cp
          ~primary_model_max_tokens
      in
      let current_generation =
        checkpoint_generation cp ~fallback:meta.runtime.generation
      in
      let base_meta =
        if current_generation = meta.runtime.generation then meta
        else
          map_runtime
            (fun rt -> { rt with generation = current_generation })
            meta
      in
      let before_tokens = token_count ctx in
      let compacted_ctx, trigger, decision =
        Keeper_compact_policy.compact_if_needed_typed ~meta:base_meta ~now_ts ctx
      in
      let compaction_decided =
        Keeper_compact_policy.compaction_decision_applied decision
      in
      (* Attempt save before updating meta so that a save failure is treated as
         compaction not applied — keeping ctx/checkpoint/metrics consistent. *)
      let effective_compaction_applied, compaction_failure_reason, effective_ctx, checkpoint =
        if not compaction_decided then (false, None, ctx, Some cp)
        else
          (* PR-J: lifecycle callbacks fire dispatch_keeper_phase_event,
             which can raise on transient registry contention or stale
             entry mismatches. The naked invocation here used to abort
             the whole post-turn lifecycle on any callback exception
             without surfacing the cause; failures now increment the
             [callback=on_compaction_started] counter, log a warn, and
             write a telemetry coverage-gap row, but the lifecycle
             continues so a downstream save error still wins the
             failure_reason field. See
             docs/architecture/actor-mailbox-pattern.md for the
             reasoning behind the keep-going-on-callback-failure
             policy. *)
          let () =
            try on_compaction_started ()
            with
            | exn ->
                Keeper_callback_failure.record ~base_dir ~meta:base_meta
                  ~callback:"on_compaction_started" exn
          in
          let session =
            create_session ~session_id:(Keeper_id.Trace_id.to_string base_meta.runtime.trace_id) ~base_dir
          in
          let compacted_ctx =
            {
              compacted_ctx with
              checkpoint =
                {
                  (checkpoint_of_context compacted_ctx) with
                  messages =
                    repair_orphan_tool_result_messages
                      (messages_of_context compacted_ctx);
                };
            }
          in
          (match save_oas_checkpoint
               ~max_checkpoint_messages:base_meta.compaction.max_checkpoint_messages
               ~session
               ~agent_name:base_meta.agent_name
               ~model ~ctx:compacted_ctx ~generation:current_generation
          with
          | Ok saved_cp -> (true, None, compacted_ctx, Some saved_cp)
          | Error e ->
              Log.Keeper.error
                "keeper:%s compaction checkpoint save failed: %s"
                base_meta.name e;
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_checkpoint_failures
                ~labels:[("keeper", base_meta.name); ("phase", "compaction_save")]
                ();
              (false, Some e, ctx, Some cp))
      in
      let after_tokens = token_count effective_ctx in
      let saved_tokens = max 0 (before_tokens - after_tokens) in
      let meta_after_compaction =
        map_runtime
          (fun rt ->
            {
              rt with
              compaction_rt =
                {
                  count =
                    rt.compaction_rt.count
                    + if effective_compaction_applied then 1 else 0;
                  last_ts =
                    if effective_compaction_applied then now_ts
                    else rt.compaction_rt.last_ts;
                  last_before_tokens =
                    if effective_compaction_applied then before_tokens
                    else rt.compaction_rt.last_before_tokens;
                  last_after_tokens =
                    if effective_compaction_applied then after_tokens
                    else rt.compaction_rt.last_after_tokens;
                  last_check_ts = now_ts;
                  last_decision =
                    Keeper_compact_policy.compaction_decision_to_string
                      decision
                    |> compaction_runtime_decision_of_string;
                };
            })
          base_meta
      in
      let rollover =
        Keeper_rollover.maybe_rollover_oas_handoff
          ~on_started:on_handoff_started
          ~base_dir
          ~meta:meta_after_compaction
          ~model
          ~primary_model_max_tokens
          ~current_turn_overflow_blocker
          ~checkpoint
      in
      let continuity_meta =
        apply_continuity_summary
          ~meta:rollover.updated_meta
          ~ctx:effective_ctx
          ~oas_checkpoint:checkpoint
      in
      {
        updated_meta = continuity_meta;
        checkpoint;
        handoff_json = rollover.handoff_json;
        handoff_attempted = rollover.attempted;
        handoff_failure_reason = rollover.failure_reason;
        compaction =
          {
            attempted = compaction_decided;
            applied = effective_compaction_applied;
            failure_reason = compaction_failure_reason;
            trigger;
            decision;
            before_tokens;
            after_tokens;
            saved_tokens;
          };
        turn_generation = current_generation;
        context_ratio = rollover.context_ratio;
        context_tokens = rollover.context_tokens;
        context_max = rollover.context_max;
        message_count = rollover.message_count;
      }
  in
  (* Strict ordering: autonomous tick → resilience classification
     → tool emission drain (K4b) → multimodal hydration (K1). Do
     not reorder — A6/K1 pinned the autonomous→resilience→multimodal
     sequence; K4b inserts between resilience and multimodal because
     it is the producer that K1 consumes. The multimodal pass runs
     last because it persists a [workspace_meta] summary that
     depends on whether prior passes have already mutated
     [working_context]. *)
  let body = apply_autonomous_wirein ~now:now_ts body in
  let body =
    apply_resilience_wirein
      ?audit_store:resilience_audit_store
      ?strategy_executor:resilience_strategy_executor
      ~now:now_ts body
  in
  let body = apply_tool_emission_wirein ~now:now_ts body in
  apply_multimodal_wirein ~now:now_ts body

let apply_post_turn_lifecycle
    ~(on_compaction_started : unit -> unit)
    ~(on_handoff_started : unit -> unit)
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(model : string)
    ~(primary_model_max_tokens : int)
    ~(current_turn_overflow_blocker : string option)
    ~(checkpoint : Agent_sdk.Checkpoint.t option) : post_turn_lifecycle =
  apply_post_turn_lifecycle_with_resilience_handles
    ~resilience_audit_store:None
    ~resilience_strategy_executor:None
    ~on_compaction_started
    ~on_handoff_started
    ~base_dir
    ~meta
    ~model
    ~primary_model_max_tokens
    ~current_turn_overflow_blocker
    ~checkpoint

let forced_overflow_retry_meta
    (meta : keeper_meta)
    ~(turn_generation : int)
    ~(now_ts : float) : keeper_meta =
  let base_meta =
    if turn_generation = meta.runtime.generation then meta
    else
      map_runtime
        (fun rt -> { rt with generation = turn_generation })
        meta
  in
  {
    (map_runtime
       (fun rt ->
         let last_continuity_update_ts =
           if rt.last_continuity_update_ts > 0.0
           then rt.last_continuity_update_ts
           else now_ts
         in
         let proactive_rt =
           if rt.proactive_rt.last_ts > 0.0
           then rt.proactive_rt
           else { rt.proactive_rt with last_ts = now_ts }
         in
         { rt with last_continuity_update_ts; proactive_rt })
       base_meta)
    with
    compaction =
      {
        base_meta.compaction with
        ratio_gate = 0.0;
        message_gate = 0;
        token_gate = 0;
        cooldown_sec = 0;
      };
  }

let recover_latest_checkpoint_for_overflow_retry
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(model : string)
    ~(primary_model_max_tokens : int) : overflow_retry_recovery option =
  let session = create_session ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~base_dir in
  let oas_result =
    Keeper_checkpoint_store.load_oas ~session_dir:session.session_dir
      ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  in
  (* P2 silent-failure fix (mirrors keeper_context_core.ml:1264 fix):
     splitting `Error Not_found | Ok _` into two arms lets a debug log
     mark when the overflow-retry path falls back from "OAS checkpoint
     missing" to a fresh start.  Operators investigating "why did
     overflow recovery use defaults?" now have the signal. *)
  (match oas_result with
   | Error (Parse_error d | Store_error d | Io_error d | Sdk_other_error d) ->
       Log.Keeper.error "keeper:%s overflow retry OAS load error: %s"
         (Keeper_id.Trace_id.to_string meta.runtime.trace_id) d;
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_oas_execution_errors
         ~labels:[("keeper", meta.name); ("phase", "overflow_retry_oas_load")]
         ()
   | Error Not_found ->
       Log.Keeper.debug
         "keeper:%s overflow-retry OAS checkpoint not found, starting fresh"
         (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
   | Ok _ -> ());
  let oas_checkpoint =
    (match oas_result with
     | Ok v -> Some v
     | Error Not_found -> None
     | Error _ ->
       Log.Keeper.warn "keeper:%s overflow-retry OAS checkpoint error discarded at to_option"
         (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
       None)
    |> Option.map (fun checkpoint ->
      let sanitized, stats =
        sanitize_oas_checkpoint ~repair_orphans:false checkpoint
      in
      if checkpoint_sanitize_changed stats then begin
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_checkpoint_failures
          ~labels:[("keeper", meta.name); ("site", "overflow_retry_migration")]
          ();
        Log.Keeper.warn
          "keeper:%s overflow-retry migration sanitized messages: dropped_blocks=%d dropped_messages=%d dropped_chars=%d truncated_blocks=%d truncated_chars=%d"
          (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          stats.dropped_blocks
          stats.dropped_messages
          stats.dropped_chars
          stats.truncated_blocks
          stats.truncated_chars;
        (match Keeper_checkpoint_store.save_oas ~session_dir:session.session_dir sanitized with
         | Ok () -> ()
         | Error detail ->
             Log.Keeper.error
               "keeper:%s overflow-retry migration save failed: %s"
               (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
               detail;
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_checkpoint_failures
               ~labels:[("keeper", meta.name); ("phase", "overflow_migration_save")]
               ())
      end;
      sanitized)
  in
  let legacy_checkpoint =
    (try load_latest_checkpoint session
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
         Log.Keeper.error "keeper:%s overflow retry checkpoint load failed: %s"
           (Keeper_id.Trace_id.to_string meta.runtime.trace_id) (Printexc.to_string exn);
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_checkpoint_failures
           ~labels:[("keeper", meta.name); ("phase", "overflow_load")]
           ();
         None)
  in
  let prefer_legacy =
    match oas_checkpoint, legacy_checkpoint with
    | Some oas, Some legacy -> legacy.timestamp > oas.created_at
    | _ -> false
  in
  let selected =
    match (prefer_legacy, oas_checkpoint, legacy_checkpoint) with
    | false, Some checkpoint, _ ->
        let turn_generation =
          checkpoint_generation checkpoint ~fallback:meta.runtime.generation
        in
        Some
          ( context_of_oas_checkpoint
              ~repair_orphans:false
              ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
              checkpoint
              ~primary_model_max_tokens,
            turn_generation )
    | _, _, Some checkpoint ->
        (try
           Some
             ( context_of_legacy_checkpoint checkpoint
                 ~primary_model_max_tokens,
               checkpoint.generation )
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
             Log.Keeper.error
               "keeper:%s overflow retry legacy checkpoint restore failed: %s"
               (Keeper_id.Trace_id.to_string meta.runtime.trace_id) (Printexc.to_string exn);
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_checkpoint_failures
               ~labels:[("keeper", meta.name); ("phase", "overflow_legacy_restore")]
               ();
             (match oas_checkpoint with
              | Some checkpoint ->
                  let turn_generation =
                    checkpoint_generation checkpoint
                      ~fallback:meta.runtime.generation
                  in
                  Some
                    ( context_of_oas_checkpoint
                        ~repair_orphans:false
                        ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
                        checkpoint
                        ~primary_model_max_tokens,
                      turn_generation )
              | None -> None))
    | _ -> None
  in
  match selected with
  | None -> None
  | Some (ctx, turn_generation) ->
      let now_ts = Time_compat.now () in
      let ctx =
        if primary_model_max_tokens <= 0 then ctx
        else
          sync_oas_context
            (with_max_tokens ctx
               (min (max_tokens_of_context ctx) primary_model_max_tokens))
      in
      let before_tokens = token_count ctx in
      let retry_meta =
        forced_overflow_retry_meta meta ~turn_generation ~now_ts
      in
      let compacted_ctx, trigger, base_decision =
        Keeper_compact_policy.compact_if_needed_typed ~meta:retry_meta ~now_ts ctx
      in
      let after_tokens = token_count compacted_ctx in
      let compaction_applied =
        Keeper_compact_policy.compaction_decision_applied base_decision
      in
      let meaningful_reduction = after_tokens < before_tokens in
      if not (compaction_applied && meaningful_reduction) then None
      else
        let compaction =
          {
            attempted = true;
            applied = true;
            failure_reason = None;
            trigger;
            decision = base_decision;
            before_tokens;
            after_tokens;
            saved_tokens = max 0 (before_tokens - after_tokens);
          }
        in
        let compacted_ctx =
          {
            compacted_ctx with
            checkpoint =
              {
                (checkpoint_of_context compacted_ctx) with
                messages =
                  repair_orphan_tool_result_messages
                    (messages_of_context compacted_ctx);
              };
          }
        in
        try
          (match save_oas_checkpoint
              ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
              ~session
              ~agent_name:retry_meta.agent_name
              ~model ~ctx:compacted_ctx ~generation:turn_generation
          with
          | Ok checkpoint ->
              Some { checkpoint; compaction; turn_generation }
          | Error e ->
              Log.Keeper.error
                "overflow retry checkpoint save failed: %s" e;
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_checkpoint_failures
                ~labels:[("keeper", retry_meta.agent_name); ("operation", "overflow_save")]
                ();
              None)
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            log_keeper_exn
              ~label:"overflow retry checkpoint save exception"
              exn;
            None
