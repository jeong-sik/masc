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

    Extracted from Keeper_exec_context as part of #4955 god-file split. *)

open Keeper_types
open Keeper_memory
open Keeper_context_core

type compaction_event = {
  attempted : bool;
  applied : bool;
  failure_reason : string option;
  trigger : string option;
  decision : string;
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

let apply_post_turn_lifecycle
    ~(on_compaction_started : unit -> unit)
    ~(on_handoff_started : unit -> unit)
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(model : string)
    ~(primary_model_max_tokens : int)
    ~(current_turn_overflow_blocker : string option)
    ~(checkpoint : Agent_sdk.Checkpoint.t option) : post_turn_lifecycle =
  let now_ts = Time_compat.now () in
  let no_checkpoint_decision = "skipped:no_checkpoint" in
  let apply_continuity_summary
      ~(meta : keeper_meta)
      ~(ctx : working_context)
      ~(oas_checkpoint : Agent_sdk.Checkpoint.t option) : keeper_meta =
    let progress_path =
      Filename.concat
        (Filename.concat (Filename.concat (Filename.dirname base_dir) "keepers") meta.name)
        "progress.md"
    in
    (* RFC-MASC-001 Phase 1: try structured working_context first,
       then fall back to text-based [STATE] parsing from messages. *)
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
        match structured_snapshot with
        | Some _ as s -> s
      | None -> latest_state_snapshot_from_messages (messages_of_context ctx)
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
               meta.name err);
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
  match checkpoint with
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
                  last_decision = no_checkpoint_decision;
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
        Keeper_compact_policy.compact_if_needed ~meta:base_meta ~now_ts ctx
      in
      let compaction_decided =
        String.starts_with ~prefix:"applied:" decision
      in
      (* Attempt save before updating meta so that a save failure is treated as
         compaction not applied — keeping ctx/checkpoint/metrics consistent. *)
      let effective_compaction_applied, compaction_failure_reason, effective_ctx, checkpoint =
        if not compaction_decided then (false, None, ctx, Some cp)
        else
          let () = on_compaction_started () in
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
                  last_decision = decision;
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
  (match oas_result with
   | Error (Parse_error d | Store_error d | Io_error d | Sdk_other_error d) ->
       Log.Keeper.error "keeper:%s overflow retry OAS load error: %s"
         (Keeper_id.Trace_id.to_string meta.runtime.trace_id) d
   | Error Not_found | Ok _ -> ());
  let oas_checkpoint =
    Result.to_option oas_result
    |> Option.map (fun checkpoint ->
      let sanitized, stats =
        sanitize_oas_checkpoint ~repair_orphans:false checkpoint
      in
      if checkpoint_sanitize_changed stats then begin
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
               detail)
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
        Keeper_compact_policy.compact_if_needed ~meta:retry_meta ~now_ts ctx
      in
      let after_tokens = token_count compacted_ctx in
      let compaction_applied =
        String.starts_with ~prefix:"applied:" base_decision
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
              None)
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            log_keeper_exn
              ~label:"overflow retry checkpoint save exception"
              exn;
            None
