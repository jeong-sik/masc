let append_entry ~keeper_name ~failure_label (acc : Trajectory.accumulator) entry =
  try
    Trajectory.append_withheld_thinking
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

(* [turn] is the per-turn index from the AGENT_CORE [after_turn] hook
   ([Hooks.AfterTurn { turn; _ }]), NOT [acc.turn]: this is invoked once per
   turn so every turn's reasoning is stamped with its own turn number. *)
let persist_response_content ~keeper_name ~trajectory_acc ~turn content =
  match trajectory_acc with
  | None -> ()
  | Some acc ->
    let now = Time_compat.now () in
    let now_iso = Masc_domain.now_iso () in
    List.iteri
      (fun block_index -> function
        | Agent_core.Types.Thinking { content; _ } ->
          let entry : Trajectory.withheld_thinking_entry =
            { ts = now
            ; ts_iso = now_iso
            ; turn
            ; block_index
            ; reasoning_kind = Trajectory.Thinking_block
            ; char_count = String.length content
            }
          in
          append_entry ~keeper_name ~failure_label:"thinking" acc entry
        | Agent_core.Types.ReasoningDetails { reasoning_content; details } ->
          let content =
            Agent_core.Types.reasoning_details_text ~reasoning_content ~details
          in
          if not (String.equal (String.trim content) "") then
            let entry : Trajectory.withheld_thinking_entry =
              { ts = now
              ; ts_iso = now_iso
              ; turn
              ; block_index
              ; reasoning_kind = Trajectory.Reasoning_details
              ; char_count = String.length content
              }
            in
            append_entry ~keeper_name ~failure_label:"reasoning details" acc entry
        | Agent_core.Types.RedactedThinking _ ->
          let entry : Trajectory.withheld_thinking_entry =
            { ts = now
            ; ts_iso = now_iso
            ; turn
            ; block_index
            ; reasoning_kind = Trajectory.Redacted_thinking
            ; char_count = 0
            }
          in
          append_entry ~keeper_name ~failure_label:"redacted thinking" acc entry
        | _ -> ())
      content
;;
