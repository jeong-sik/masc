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
    Log.Keeper.error ~keeper_name:keeper_name
      "%s persist failed: %s"
      failure_label
      (Printexc.to_string exn);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ThinkingPersistFailures)
      ~labels:[ "keeper", keeper_name ]
      ()
;;

(* [turn] is the per-turn index from the OAS [after_turn] hook
   ([Hooks.AfterTurn { turn; _ }]), NOT [acc.turn]: this is invoked once per
   turn so every turn's reasoning is stamped with its own turn number. *)
let persist_response_content ~keeper_name ~trajectory_acc ~turn content =
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
            ; turn
            ; content
            ; content_length = String.length content
            ; redacted = false
            }
          in
          append_entry ~keeper_name ~failure_label:"thinking" acc entry
        | Agent_sdk.Types.ReasoningDetails { reasoning_content; details } ->
          let content =
            Agent_sdk.Types.reasoning_details_text ~reasoning_content ~details
          in
          if not (String.equal (String.trim content) "") then
            let entry : Trajectory.thinking_entry =
              { ts = now
              ; ts_iso = now_iso
              ; turn
              ; content
              ; content_length = String.length content
              ; redacted = false
              }
            in
            append_entry ~keeper_name ~failure_label:"reasoning details" acc entry
        | Agent_sdk.Types.RedactedThinking _ ->
          let entry : Trajectory.thinking_entry =
            { ts = now
            ; ts_iso = now_iso
            ; turn
            ; content = "[redacted]"
            ; content_length = 0
            ; redacted = true
            }
          in
          append_entry ~keeper_name ~failure_label:"redacted thinking" acc entry
        | _ -> ())
      content
;;
