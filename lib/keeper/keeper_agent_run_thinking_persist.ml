let persist ~trajectory_acc ~content ~keeper_name =
  match trajectory_acc with
  | None -> ()
  | Some acc ->
    let now = Time_compat.now () in
    let now_iso = Masc_domain.now_iso () in
    List.iter
      (function
        | Agent_sdk.Types.Thinking { content; _ } ->
          let entry : Trajectory.thinking_entry =
            { ts = now
            ; ts_iso = now_iso
            ; turn = acc.Trajectory.turn
            ; content
            ; content_length = String.length content
            ; redacted = false
            }
          in
          (try
             Trajectory.append_thinking
               ~masc_root:acc.Trajectory.masc_root
               ~keeper_name:acc.Trajectory.keeper_name
               ~trace_id:acc.Trajectory.trace_id
               entry
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Keeper.error
               "keeper:%s thinking persist failed: %s"
               keeper_name
               (Printexc.to_string exn);
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_thinking_persist_failures
               ~labels:[ "keeper", keeper_name ]
               ())
        | Agent_sdk.Types.RedactedThinking _ ->
          let entry : Trajectory.thinking_entry =
            { ts = now
            ; ts_iso = now_iso
            ; turn = acc.Trajectory.turn
            ; content = "[redacted]"
            ; content_length = 0
            ; redacted = true
            }
          in
          (try
             Trajectory.append_thinking
               ~masc_root:acc.Trajectory.masc_root
               ~keeper_name:acc.Trajectory.keeper_name
               ~trace_id:acc.Trajectory.trace_id
               entry
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Keeper.error
               "keeper:%s redacted thinking persist failed: %s"
               keeper_name
               (Printexc.to_string exn);
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_thinking_persist_failures
               ~labels:[ "keeper", keeper_name ]
               ())
        | _ -> ())
      content
;;
