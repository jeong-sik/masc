(** See [keeper_world_observation_continuity.mli] for the contract. *)

open Keeper_types
open Keeper_memory
open Keeper_exec_context

(* Observability for the 6-path fallback chain in
   [read_continuity_summary]. Until this counter existed, the
   meta-level [continuity_fallback_summary_text] was returned from
   three distinct paths (no_snapshot / no_ctx / exception) without
   any signal, and the catch-all [| _ -> ] silently swallowed every
   non-Cancelled exception. *)
let () =
  Prometheus.register_counter
    ~name:Keeper_metrics.metric_keeper_continuity_summary_source
    ~help:
      "Total [read_continuity_summary] returns, classified by label \
       [source] (governed by Keeper_continuity_summary_source).  \
       Label [keeper] names the keeper.  Rising \
       [meta_fallback_exception] is the operational signal that the \
       catch-all in [read_continuity_summary] is swallowing \
       exceptions."
    ()
;;

let record_continuity_summary_source ~(keeper_name : string)
    ~(source : Keeper_continuity_summary_source.t) =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_continuity_summary_source
    ~labels:
      [ ("source", Keeper_continuity_summary_source.to_label source)
      ; ("keeper", keeper_name)
      ]
    ()

(** Read continuity summary from checkpoint messages or meta fallback. *)
let read_continuity_summary ~(config : Coord.config) ~(meta : keeper_meta) : string =
  let render_bounded_snapshot snapshot =
    keeper_state_snapshot_to_summary_text snapshot
    |> Keeper_memory_policy.cap_continuity_summary_text
  in
  let meta_fallback ~source =
    record_continuity_summary_source ~keeper_name:meta.name ~source;
    continuity_fallback_summary_text
      ~continuity_summary:meta.continuity_summary
      ~last_continuity_update_ts:meta.runtime.last_continuity_update_ts
  in
  try
    match Keeper_memory_policy.read_progress_snapshot ~config ~name:meta.name with
    | Some snapshot ->
      record_continuity_summary_source
        ~keeper_name:meta.name
        ~source:Keeper_continuity_summary_source.Progress_snapshot;
      render_bounded_snapshot snapshot
    | None ->
      let cascade_models = Keeper_model_labels.configured_model_labels_of_meta meta in
      let primary_max_context =
        let resolution =
          Keeper_exec_context.resolve_max_context_resolution
            ~requested_override:meta.max_context_override
            cascade_models
        in
        resolution.effective_budget
      in
      let base_dir = session_base_dir config in
      let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
      let session, ctx_opt =
        load_context_from_checkpoint
          ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
          ~trace_id
          ~primary_model_max_tokens:primary_max_context
          ~base_dir
      in
      (match ctx_opt with
       | Some c ->
         let structured_snapshot =
           match
             Keeper_checkpoint_store.load_oas
               ~session_dir:session.session_dir
               ~session_id:trace_id
           with
           | Ok cp ->
             (match cp.Agent_sdk.Checkpoint.working_context with
              | Some json ->
                Keeper_memory_policy.snapshot_of_structured_working_context json
              | None -> None)
           | Error _ -> None
         in
         let state_block_snapshot =
           latest_state_snapshot_from_messages (messages_of_context c)
         in
         let snapshot, source =
           match state_block_snapshot with
           | Some _ as snap ->
             snap, Some Keeper_continuity_summary_source.Checkpoint_state_block
           | None ->
             (match structured_snapshot with
              | Some _ as snap ->
                snap, Some Keeper_continuity_summary_source.Checkpoint_structured
              | None -> None, None)
         in
         (match snapshot, source with
          | Some s, Some src ->
            record_continuity_summary_source ~keeper_name:meta.name ~source:src;
            render_bounded_snapshot s
          | _ ->
            meta_fallback
              ~source:Keeper_continuity_summary_source.Meta_fallback_no_snapshot)
       | None ->
         meta_fallback ~source:Keeper_continuity_summary_source.Meta_fallback_no_ctx)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "keeper:%s read_continuity_summary caught exception in fallback \
       chain (%s) -- using meta_fallback; investigate progress \
       snapshot or checkpoint store"
      meta.name
      (Printexc.to_string exn);
    meta_fallback ~source:Keeper_continuity_summary_source.Meta_fallback_exception
;;
