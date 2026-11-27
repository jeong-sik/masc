(** Keeper_agent_run_post_turn_memory.ml — Post-turn memory write series.

    Extracted from [Keeper_agent_run.run_turn]. *)

let completed_history_changed ~config ~keeper_name =
  match Env_config.KeeperMemoryOs.librarian_config_state () with
  | Disabled | Invalid -> ()
  | Enabled ->
    Keeper_working_context_signal.changed
      ~base_path:config.Workspace.base_path ~keeper_name
;;

let run
  ~config
  ~(meta : Keeper_meta_contract.keeper_meta)
  ~turn
  ~agent_core_turn_count
  ~checkpoint_owner
  ~post_turn_t0
  ~inference_telemetry
  ()
  =
  (* Both kinds of turn leave their record on disk before this runs -- the
     checkpoint and its end line for an Agent-Core turn, the history fragments
     and an end line for an official-client turn -- and the durable consumer
     reads both from there. The turn hands over nothing else. The librarian
     toggle is owned at this admission boundary: disabled or invalid
     configuration wakes nothing. *)
  (match checkpoint_owner with
   | Runtime_execution.Masc_agent_core | Runtime_execution.Official_client ->
     completed_history_changed ~config ~keeper_name:meta.name);
  (* Post-turn timing evidence is logged to decisions.jsonl. *)
  (try
     let post_turn_ms =
       Keeper_timing.round1
         ((Time_compat.now () -. post_turn_t0) *. 1000.0)
     in
     let eval_json =
       `Assoc
         ([ "ts_unix", `Float (Time_compat.now ())
          ; "event", `String "post_turn_eval"
          ; "keeper_name", `String meta.name
          ; "turn", `Int turn
          ; "agent_core_turn_count", `Int agent_core_turn_count
          ; "post_turn_ms", `Float post_turn_ms
          ]
          @ (match inference_telemetry with
             | Some t ->
               [ ( "inference_telemetry"
                 , Keeper_hooks_agent_core.inference_telemetry_to_runtime_json t )
               ]
             | None -> []))
     in
     Keeper_types_support.append_decision_record config meta.name eval_json
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string DispatchEventFailures)
       ~labels:[ "keeper", meta.name; "site", "post_turn_eval" ]
       ();
     Log.Keeper.warn ~keeper_name:meta.name
       "post_turn_eval jsonl append failed: %s"
       (Printexc.to_string exn))
;;
