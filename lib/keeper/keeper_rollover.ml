(** Keeper_rollover — OAS handoff rollover logic.

    When a keeper's context ratio exceeds the handoff threshold and
    cooldown has elapsed, creates a new session with the current context
    carried forward to the next generation.

    Extracted from Keeper_exec_context as part of #4955 god-file split. *)

open Keeper_types
open Keeper_context_core

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

let maybe_rollover_oas_handoff
    ~(on_started : unit -> unit)
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(model : string)
    ~(primary_model_max_tokens : int)
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
      let ctx = context_of_oas_checkpoint ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages cp ~primary_model_max_tokens in
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
      let rollover_base =
        {
          updated_meta = base_meta;
          handoff_json = None;
          attempted = false;
          failure_reason = None;
          context_ratio = ratio;
          context_tokens = token_count ctx;
          context_max = ctx.max_tokens;
          message_count = message_count ctx;
        }
      in
      if
        not base_meta.auto_handoff
        || ratio < base_meta.handoff_threshold
        || not cooldown_elapsed
      then
        rollover_base
      else
        let now_ts = Time_compat.now () in
        let prev_trace_id = base_meta.runtime.trace_id in
        let new_trace_id = Keeper_identity.generate_trace_id () in
        let next_generation = current_generation + 1 in
        on_started ();
        (try
          let new_session =
            create_session ~session_id:new_trace_id ~base_dir
          in
          match save_oas_checkpoint
                  ~max_checkpoint_messages:base_meta.compaction.max_checkpoint_messages
                  ~session:new_session
                  ~agent_name:base_meta.agent_name
                  ~model ~ctx ~generation:next_generation with
          | Error e ->
              Log.Keeper.error
                "keeper:%s OAS handoff rollover ABORTED — checkpoint save failed: %s"
                base_meta.name e;
              { rollover_base with attempted = true; failure_reason = Some e }
          | Ok _checkpoint ->
              (match Keeper_id.Trace_id.of_string new_trace_id with
               | Error err ->
                 Log.Keeper.error
                   "keeper:%s OAS handoff rollover ABORTED — generated invalid trace_id %s: %s"
                   base_meta.name new_trace_id err;
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
                     ]
                 in
                 Log.Keeper.info
                   "keeper:%s OAS handoff rollover trace=%s->%s gen=%d->%d ratio=%.3f"
                   base_meta.name (Keeper_id.Trace_id.to_string prev_trace_id) new_trace_id current_generation
                   next_generation ratio;
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
            })
