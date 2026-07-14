(** Keeper_post_turn — post-turn lifecycle: compaction and overflow retry recovery.

    Orchestrates the end-of-turn checkpoint pipeline.

    This module owns only the checkpoint/lineage tail of a keeper turn.
    Memory bank append, episode flush, and Hebbian learning are recorded
    elsewhere:
    - memory bank / episodes: [Keeper_agent_run] tail after [Agent.run]
    - hebbian: task lifecycle in [Workspace_task]

    Extracted from Keeper_context_runtime as part of #4955 god-file split.

    Spec navigation (OCaml -> TLA+) — plan §19 anchor pattern.  Sibling
    Authoritative spec
    mirror is [specs/keeper-state-machine/KeeperGenerationLineage.tla].

    Spec lines 10-13 already cite this module as one of three modeled
    OCaml sources:
      - lib/keeper/keeper_post_turn.ml   (this file — post-turn pipeline)
      - lib/keeper_types/keeper_types.mli (type lineage — anchor deferred)

    This block is the reverse-direction citation so code search for
    "KeeperGenerationLineage" lands here.

    Post-turn -> spec mapping:
      Compaction phase    feeds into [keeper_phase] = "running" while
                          the in-flight turn is still resolving.
      Checkpoint commit    preserves the spec's checkpoint-valid /
                          checkpoint-generation parity invariant.

    Spec scope (line 4-8): same identity across generations,
    trace_id replacement, append-only ancestry, checkpoint lineage
    parity once back to idle.

    Spec out-of-scope (line 15-18 in spec): explicit compaction requests,
    Agent.run turn loop, and long-term memory recall. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_core

type compaction_event = {
  attempted : bool;
  applied : bool;
  (** [started_dispatched] is [true] when the [on_compaction_started] callback
      successfully dispatched [Compaction_started] to the registry, placing the
      FSM in [Compaction_compacting].  When [false] (callback failed, skipped,
      or not attempted), the FSM is still at [Compaction_accumulating] and
      [dispatch_post_turn_lifecycle_events] must dispatch [Compaction_started]
      before [Compaction_completed] to avoid the forbidden
      accumulating -> done transition. *)
  started_dispatched : bool;
  failure_reason : string option;
  trigger : Compaction_trigger.t option;
  decision : Keeper_compact_policy.compaction_decision;
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

type compaction_recovery_error =
  | Checkpoint_load_failed of Keeper_checkpoint_store.checkpoint_load_error
  | Compaction_rejected of Keeper_compact_policy.compaction_rejection
  | Unexpected_compaction_decision of Keeper_compact_policy.compaction_decision
  | Checkpoint_superseded of {
      incoming_turn_count : int;
      known_turn_count : int;
    }
  | Checkpoint_save_failed of string
  | Checkpoint_save_raised of exn

let compaction_recovery_error_to_tag = function
  | Checkpoint_load_failed Not_found -> "checkpoint_not_found"
  | Checkpoint_load_failed _ -> "checkpoint_load_failed"
  | Compaction_rejected Retired_deterministic_mode -> "retired_deterministic_mode"
  | Compaction_rejected Runtime_unavailable -> "runtime_unavailable"
  | Compaction_rejected Summarizer_unavailable_or_invalid ->
    "summarizer_unavailable_or_invalid"
  | Compaction_rejected Structural_noop -> "structural_noop"
  | Unexpected_compaction_decision _ -> "unexpected_compaction_decision"
  | Checkpoint_superseded _ -> "checkpoint_superseded"
  | Checkpoint_save_failed _ -> "checkpoint_save_failed"
  | Checkpoint_save_raised _ -> "checkpoint_save_raised"

let checkpoint_load_error_detail = function
  | Keeper_checkpoint_store.Not_found -> "checkpoint not found"
  | Store_error detail
  | Parse_error detail
  | Io_error detail
  | Sdk_other_error detail -> detail

let compaction_recovery_error_to_string = function
  | Checkpoint_load_failed error -> checkpoint_load_error_detail error
  | Compaction_rejected reason ->
    (match reason with
     | Retired_deterministic_mode -> "deterministic compaction is retired"
     | Runtime_unavailable -> "compaction runtime unavailable"
     | Summarizer_unavailable_or_invalid -> "compaction plan unavailable or invalid"
     | Structural_noop -> "compaction plan produced no structural change")
  | Unexpected_compaction_decision decision ->
    "unexpected decision: " ^ Keeper_compact_policy.compaction_decision_to_string decision
  | Checkpoint_superseded { incoming_turn_count; known_turn_count } ->
    Printf.sprintf
      "checkpoint superseded: incoming_turn_count=%d known_turn_count=%d"
      incoming_turn_count
      known_turn_count
  | Checkpoint_save_failed detail -> detail
  | Checkpoint_save_raised exn -> Printexc.to_string exn

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
   call them without depending on the full [masc] library. The
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
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PostTurnWireinFailures)
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
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PostTurnWireinFailures)
            ~labels:[("keeper", lifecycle.updated_meta.name); ("phase", "resilience")]
            ();
          lifecycle)

(* ── Tier K1: multimodal post-turn wire-in (Cycle 27) ─────────────
   Wire-in that runs after the A5/A6 pair. Reads
   raw multimodal artifacts the keeper agent dropped into
   [working_context["multimodal_artifacts"]], hydrates them via
   [Multimodal_keeper_bridge.hydrate_one], and accumulates them into
   the process-wide [Multimodal.Workspace_holder].

   It consumes the artifact bag and replaces it with a [workspace_meta]
   summary so the next turn does not re-process the same entries.

   Failures inside the wire-in do not propagate — they are logged
   and the unmodified lifecycle result is returned, preserving the
   keeper's primary turn outcome. *)

(* ── Tier K4b: tool-emission drain (Cycle 27) ──────────────────────
   Drains producer-owned typed JSON captured at the Keeper tool execution
   boundary into [working_context["multimodal_artifacts"]] so the
   K1 wirein below picks them up.

   Strict ordering: this MUST run BEFORE [apply_multimodal_wirein].
   K4b emit + K1 hydrate is a producer/consumer pair on the same
   working_context bag.

   Typed tool emission is a normal Keeper capability, not a rollout gate. *)
let apply_tool_emission_wirein
    ~(now : float)
    (lifecycle : post_turn_lifecycle) : post_turn_lifecycle =
  let _ = now in
  match lifecycle.checkpoint with
  | None -> lifecycle
  | Some cp -> (
        try
          let acc =
            (* Tier K4c — pull THIS keeper's accumulator. The typed execution
               boundary records items under the same stable keeper name. *)
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
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PostTurnWireinFailures)
            ~labels:[("keeper", lifecycle.updated_meta.name); ("phase", "tool_emission_drain")]
            ();
          lifecycle)

let apply_multimodal_wirein
    ~(now : float)
    (lifecycle : post_turn_lifecycle) : post_turn_lifecycle =
  match lifecycle.checkpoint with
  | None -> lifecycle
  | Some cp ->
    (match
       Multimodal.Wirein_helpers.extract_raw_artifacts
         cp.Agent_sdk.Checkpoint.working_context
     with
     | Error detail ->
       Log.Keeper.warn
         "keeper:%s multimodal wire-in contract unavailable: %s"
         lifecycle.updated_meta.name
         detail;
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string PostTurnWireinFailures)
         ~labels:[ ("keeper", lifecycle.updated_meta.name); ("phase", "multimodal_contract") ]
         ();
       lifecycle
     | Ok (raws, wc_rest) ->
       (try
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
                ( "last_artifact_id", Json_util.string_opt_to_json !last_id );
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
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PostTurnWireinFailures)
            ~labels:[("keeper", lifecycle.updated_meta.name); ("phase", "multimodal")]
            ();
          lifecycle))

let apply_post_turn_lifecycle_with_resilience_handles
    ~(resilience_audit_store : Shared_audit.Store.t option)
    ~(resilience_strategy_executor : Resilience.Recovery.strategy_executor option)
    ~on_compaction_started:_
    ~on_handoff_started:_
    ~base_dir:_
    ~(meta : keeper_meta)
    ~model:_
    ~(primary_model_max_tokens : int)
    ~current_turn_blocker_info:_
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
            started_dispatched = false;
            failure_reason = None;
            trigger = None;
            decision = no_checkpoint_decision;
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
      let decision = Keeper_compact_policy.Not_requested in
      let meta_after_compaction =
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
                      decision
                    |> compaction_runtime_decision_of_string;
                };
            })
          base_meta
      in
      {
        updated_meta = meta_after_compaction;
        checkpoint = Some cp;
        handoff_json = None;
        handoff_attempted = false;
        handoff_failure_reason = None;
        compaction =
          {
            attempted = false;
            applied = false;
            started_dispatched = false;
            failure_reason = None;
            trigger = None;
            decision;
          };
        turn_generation = current_generation;
        context_ratio = context_ratio ctx;
        context_tokens = token_count ctx;
        context_max = max_tokens_of_context ctx;
        message_count = message_count ctx;
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

let recover_latest_checkpoint_for_overflow_retry
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(trigger : Compaction_trigger.t)
    ~(primary_model_max_tokens : int)
  : (overflow_retry_recovery, compaction_recovery_error) result
  =
  let session = create_session ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~base_dir in
  match
    Keeper_checkpoint_store.load_oas ~session_dir:session.session_dir
      ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  with
  | Error Not_found ->
    Log.Keeper.debug
      "keeper:%s overflow-retry OAS checkpoint not found"
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
    Error (Checkpoint_load_failed Not_found)
  | Error ((Parse_error detail | Store_error detail | Io_error detail
           | Sdk_other_error detail) as error) ->
    Log.Keeper.error
      "keeper:%s overflow retry OAS load error: %s"
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      detail;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string OasExecutionErrors)
      ~labels:
        [ "keeper", meta.name
        ; ( "phase"
          , Keeper_oas_execution_error_phase.(to_label Overflow_retry_oas_load) )
        ]
      ();
    Error (Checkpoint_load_failed error)
  | Ok checkpoint ->
    let turn_generation =
      checkpoint_generation checkpoint ~fallback:meta.runtime.generation
    in
    let ctx = context_of_oas_checkpoint checkpoint ~primary_model_max_tokens in
      let retry_meta =
        if turn_generation = meta.runtime.generation then meta
        else map_runtime (fun rt -> { rt with generation = turn_generation }) meta
      in
      let compacted_ctx, base_decision =
        Keeper_compact_policy.compact_for_request_typed
          ~meta:retry_meta
          ~trigger
          ctx
      in
      match base_decision with
      | Keeper_compact_policy.Prepared prepared_trigger ->
        (try
          (match save_oas_checkpoint_classified
              ~multimodal_policy:meta.multimodal_policy
              ~keeper_name:meta.name
              ~session
              ~agent_name:retry_meta.agent_name
              ~ctx:compacted_ctx ~generation:turn_generation
          with
          | Ok (checkpoint, Keeper_checkpoint_store.Saved _) ->
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string Compactions)
                ~labels:[ "keeper", retry_meta.name ]
                ();
              Ok
                { checkpoint
                ; compaction =
                    { attempted = true
                    ; applied = true
                    ; started_dispatched = false
                    ; failure_reason = None
                    ; trigger = Some prepared_trigger
                    ; decision = Keeper_compact_policy.Applied prepared_trigger
                    }
                ; turn_generation
                }
          | Ok
              ( _,
                Keeper_checkpoint_store.Stale_noop
                  { incoming_turn_count; known_turn_count } ) ->
            Log.Keeper.warn
              "overflow retry checkpoint superseded: incoming_turn_count=%d known_turn_count=%d"
              incoming_turn_count
              known_turn_count;
            Error
              (Checkpoint_superseded
                 { incoming_turn_count; known_turn_count })
          | Error e ->
              Log.Keeper.error
                "overflow retry checkpoint save failed: %s" e;
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string CheckpointFailures)
                ~labels:[("keeper", retry_meta.agent_name); ("operation", "overflow_save")]
                ();
              Error (Checkpoint_save_failed e))
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            log_keeper_exn
              ~label:"overflow retry checkpoint save exception"
              exn;
            Error (Checkpoint_save_raised exn))
      | Keeper_compact_policy.Rejected (_, reason) ->
        Error (Compaction_rejected reason)
      | decision -> Error (Unexpected_compaction_decision decision)
