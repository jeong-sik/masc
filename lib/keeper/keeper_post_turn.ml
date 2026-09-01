(** Keeper_post_turn — post-turn checkpoint preservation.

    Orchestrates the end-of-turn checkpoint pipeline.

    This module owns only the checkpoint/lineage tail of a keeper turn.
    Current-memory selection runs in
    [Keeper_agent_run_post_turn_memory]; task learning remains in
    [Workspace_task].

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_core

type post_turn_lifecycle = {
  updated_meta : keeper_meta;
  checkpoint : Agent_core.Checkpoint.t option;
  checkpoint_bytes : int;
  message_count : int;
}


let apply_tool_emission_wirein
    (lifecycle : post_turn_lifecycle) : post_turn_lifecycle =
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
              ~working_context:cp.Agent_core.Checkpoint.working_context
          in
          let new_cp =
            { cp with Agent_core.Checkpoint.working_context = new_wc }
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
         cp.Agent_core.Checkpoint.working_context
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
          let artifacts =
            Multimodal.Multimodal_keeper_bridge.hydrate_batch
              raws
              ~now
              ~created_by:lifecycle.updated_meta.name
          in
          let last_id =
            match List.rev artifacts with
            | [] -> None
            | last :: _ ->
              Some
                (Shared_types.Artifact_id.to_string
                   (Multimodal.Artifact.any_id last))
          in
          let workspace_size =
            Multimodal.Workspace_holder.update (fun workspace ->
              let next =
                List.fold_left
                  Multimodal.Workspace.add
                  workspace
                  artifacts
              in
              next, Multimodal.Workspace.size next)
          in
          let meta =
            `Assoc
              [
                ("workspace_size", `Int workspace_size);
                ( "last_artifact_id", Json_util.string_opt_to_json last_id );
                ("at", `Float now);
              ]
          in
          let new_wc =
            Multimodal.Wirein_helpers.upsert_workspace_meta wc_rest
              meta
          in
          let new_cp =
            { cp with Agent_core.Checkpoint.working_context = new_wc }
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

let apply_post_turn_lifecycle
    ~(meta : keeper_meta)
    ~(checkpoint : Agent_core.Checkpoint.t option) : post_turn_lifecycle =
  let now_ts = Time_compat.now () in
  let body = match checkpoint with
  | None ->
      let updated_meta = meta in
      {
        updated_meta;
        checkpoint = None;
        checkpoint_bytes = 0;
        message_count = 0;
      }
  | Some cp ->
      let ctx = context_of_agent_core_checkpoint cp in
      let base_meta = meta in
      let meta_after_context_check = base_meta in
      {
        updated_meta = meta_after_context_check;
        checkpoint = Some cp;
        checkpoint_bytes = serialized_bytes ctx;
        message_count = message_count ctx;
      }
  in
  (* Strict ordering: tool emission drain (K4b) → multimodal hydration (K1).
     K4b precedes multimodal because it is the producer that K1 consumes. The
     multimodal pass runs last because it persists a [workspace_meta] summary
     that depends on whether the prior pass has already mutated
     [working_context]. *)
  let body = apply_tool_emission_wirein body in
  apply_multimodal_wirein ~now:now_ts body
