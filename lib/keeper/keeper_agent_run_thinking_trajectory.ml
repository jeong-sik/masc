let append_entry ~keeper_name ~failure_label (acc : Trajectory.accumulator) entry =
  try
    Trajectory.append_thinking
      ~masc_root:acc.Trajectory.masc_root
      ~keeper_name:acc.Trajectory.keeper_name
      ~trace_id:acc.Trajectory.trace_id
      entry
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.error
      "keeper:%s %s persist failed: %s"
      keeper_name
      failure_label
      (Printexc.to_string exn);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ThinkingPersistFailures)
      ~labels:[ "keeper", keeper_name ]
      ()
;;

let persist_response_content ~keeper_name ~trajectory_acc content =
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
          append_entry ~keeper_name ~failure_label:"thinking" acc entry
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
          append_entry ~keeper_name ~failure_label:"redacted thinking" acc entry
        | _ -> ())
      content
;;
