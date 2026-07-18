let record_entry ~keeper_name ~failure_label (acc : Trajectory.accumulator) entry =
  try
    Trajectory.record_thinking acc entry
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.error ~keeper_name:keeper_name
      "%s queue failed: %s"
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
    List.iteri
      (fun block_index block ->
        match block with
        | (Agent_sdk.Types.Thinking _
          | Agent_sdk.Types.ReasoningDetails _
          | Agent_sdk.Types.RedactedThinking _) as block ->
          (match
             Trajectory.make_thinking_entry ~ts:now ~ts_iso:now_iso ~turn
               ~block_index ~block
           with
           | Ok entry ->
               record_entry ~keeper_name ~failure_label:"reasoning block" acc
                 entry
           | Error error ->
               Log.Keeper.error ~keeper_name
                 "reasoning block rejected before persistence: %s"
                 (Trajectory.entry_decode_error_to_string error);
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string ThinkingPersistFailures)
                 ~labels:[ "keeper", keeper_name ] ())
        | _ -> ())
      content
;;
