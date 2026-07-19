let report_coverage_gap ~keeper_name (acc : Trajectory.accumulator)
    ~stale_reason exn =
  let masc_root = Trajectory.accumulator_masc_root acc in
  let trace_id = Trajectory.accumulator_trace_id acc in
  try
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"trajectory"
      ~producer:"keeper_agent_run_thinking_trajectory.after_turn"
      ~durable_store:
        (Trajectory.trajectory_path masc_root
           (Trajectory.accumulator_keeper_name acc) trace_id)
      ~dashboard_surface:"/api/v1/keepers/:name/trajectory"
      ~stale_reason
      ~keeper_name
      ~trace_id
      ~exn
      ()
  with
  | Eio.Cancel.Cancelled _ as cancel -> raise cancel
  | gap_exn ->
    Log.Keeper.error ~keeper_name
      "reasoning trajectory coverage-gap write failed: %s"
      (Printexc.to_string gap_exn)
;;

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
      ();
    report_coverage_gap ~keeper_name acc
      ~stale_reason:"trajectory_thinking_queue_failed" exn
;;

(* [oas_turn] is the exact index from the OAS [after_turn] hook. The absolute
   Keeper clock is owned by the turn-scoped accumulator. *)
let persist_response_content ~keeper_name ~trajectory_acc ~oas_turn content =
  match trajectory_acc with
  | None -> ()
  | Some acc ->
    let keeper_turn_id = Trajectory.accumulator_keeper_turn_id acc in
    let now = Time_compat.now () in
    let now_iso = Masc_domain.now_iso () in
    List.iteri
      (fun block_index block ->
        match block with
        | (Agent_sdk.Types.Thinking _
          | Agent_sdk.Types.ReasoningDetails _
          | Agent_sdk.Types.RedactedThinking _) as block ->
          (match
             Trajectory.make_thinking_entry ~ts:now ~ts_iso:now_iso
               ~keeper_turn_id ~oas_turn ~block_index ~block
           with
           | Ok entry ->
               record_entry ~keeper_name ~failure_label:"reasoning block" acc
                 entry
           | Error error ->
               let exn =
                 Invalid_argument
                   (Trajectory.entry_decode_error_to_string error)
               in
               Log.Keeper.error ~keeper_name
                 "reasoning block rejected before persistence: %s"
                 (Trajectory.entry_decode_error_to_string error);
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string ThinkingPersistFailures)
                 ~labels:[ "keeper", keeper_name ] ();
               report_coverage_gap ~keeper_name acc
                 ~stale_reason:"trajectory_thinking_entry_invalid" exn)
        | Agent_sdk.Types.Text _
        | Agent_sdk.Types.ToolUse _
        | Agent_sdk.Types.ToolResult _
        | Agent_sdk.Types.Image _
        | Agent_sdk.Types.Document _
        | Agent_sdk.Types.Audio _ ->
          ())
      content
;;
