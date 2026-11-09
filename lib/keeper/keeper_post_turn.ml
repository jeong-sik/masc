(** Keeper_post_turn — post-turn checkpoint preservation.

    Orchestrates the end-of-turn checkpoint pipeline.

    This module owns only the checkpoint/lineage tail of a keeper turn.
    Current-memory selection runs in
    [Keeper_agent_run_post_turn_memory]; task learning remains in
    [Workspace_task].

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

open Keeper_meta_contract
open Keeper_context_core

type post_turn_lifecycle = {
  updated_meta : keeper_meta;
  checkpoint_bytes : int option;
  message_count : int;
}

(* The store answers from the summary it published when this process wrote
   the file, so no part of the context is serialised here. Until 2026-09-05
   this re-encoded the whole history to JSON once per turn only to take its
   length (RFC main-domain-scheduler-latency section 8.7). *)
let durable_checkpoint_bytes ~(config : Workspace.config) ~(meta : keeper_meta) =
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
  match
    Keeper_checkpoint_store.canonical_byte_count ~session_dir ~session_id:trace_id
  with
  | Ok bytes -> Ok bytes
  | Error error ->
    Error (Keeper_checkpoint_store.checkpoint_load_error_to_string error)

let apply_post_turn_lifecycle
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(checkpoint : Agent_core.Checkpoint.t option) : post_turn_lifecycle =
  match checkpoint with
  | None ->
      let updated_meta = meta in
      {
        updated_meta;
        checkpoint_bytes = None;
        message_count = 0;
      }
  | Some cp ->
      let ctx = context_of_agent_core_checkpoint cp in
      let base_meta = meta in
      let meta_after_context_check = base_meta in
      {
        updated_meta = meta_after_context_check;
        checkpoint_bytes =
          (match durable_checkpoint_bytes ~config ~meta with
           | Ok bytes -> bytes
           | Error detail ->
             Log.Keeper.warn
               "keeper:%s checkpoint byte count unavailable: %s"
               meta.name detail;
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string PostTurnWireinFailures)
               ~labels:[("keeper", meta.name); ("phase", "checkpoint_bytes")]
               ();
             None);
        message_count = message_count ctx;
      }
