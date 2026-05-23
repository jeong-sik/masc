open Keeper_hooks_oas_types

let render_pre_tool_gate_source_hint
    (event : Keeper_guards.gate_decision_event) =
  match event.source_path, event.source_line with
  | None, None -> ""
  | Some path, None ->
      Printf.sprintf " source_path=%s" (Keeper_guards.escape_field path)
  | None, Some line -> Printf.sprintf " source_line=%d" line
  | Some path, Some line ->
      Printf.sprintf " source_path=%s source_line=%d"
        (Keeper_guards.escape_field path) line

let tool_approval_required_tag = "[tool_approval_required]"

let render_pre_tool_gate_output (event : Keeper_guards.gate_decision_event) =
  if event.decision = Keeper_guards.Gate_approval_required then
    Printf.sprintf
      "%s tool=%s source=keeper_hook code=%s reason=%s%s"
      tool_approval_required_tag
      (Keeper_guards.escape_field event.tool_name)
      (Keeper_guards.escape_field event.reason_code)
      (Keeper_guards.escape_field event.reason_text)
      (render_pre_tool_gate_source_hint event)
  else
    match event.source_path, event.source_line with
    | Some source_path, Some source_line ->
        Keeper_guards.render_inline_skip_reason_with_source
          ~source_path
          ~source_line
          ~tool_name:event.tool_name
          ~reason_code:event.reason_code
          ~reason_text:event.reason_text
    | _ ->
        Keeper_guards.render_inline_skip_reason
          ~tool_name:event.tool_name
          ~reason_code:event.reason_code
          ~reason_text:event.reason_text

let pre_tool_gate_error (event : Keeper_guards.gate_decision_event) =
  let decision = Keeper_guards.gate_decision_to_string event.decision in
  Printf.sprintf "%s:%s: %s" decision event.reason_code event.reason_text

let min_duration_ms = 0.0

let trajectory_duration_ms duration_ms =
  if
    (not (Float.is_finite duration_ms))
    || Float.compare duration_ms min_duration_ms <= 0
  then 0
  else max 1 (int_of_float (Float.round duration_ms))

let record_pre_tool_gate_attempt
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~(tool_call_count_ref : int ref)
    ?(trajectory_acc : Trajectory.accumulator option)
    (event : Keeper_guards.gate_decision_event) =
  incr tool_call_count_ref;
  let meta = !meta_ref in
  let keeper_name = meta.name in
  let model = current_keeper_model meta in
  let safe_input = Observability_redact.redact_json_value event.input in
  let output_text = render_pre_tool_gate_output event in
  let error = pre_tool_gate_error event in
  let duration_ms = Float.max 0.0 event.stage_latency_ms in
  (try
     Keeper_tool_call_log.log_call
       ~keeper_name
       ~tool_name:event.tool_name
       ~input:safe_input
       ~output_text
       ~success:false
       ~duration_ms
       ~model
       ~result_bytes:(String.length output_text)
       ()
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
       let callback_label_gate_tool_call_log = "gate_tool_call_log" in
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_lifecycle_callback_failures
         ~labels:
           [
             (label_keeper, keeper_name);
             (label_callback, callback_label_gate_tool_call_log);
           ]
         ();
       Log.Keeper.warn
         "keeper:%s pre_tool_use gate tool_call log failed tool=%s err=%s"
         keeper_name event.tool_name (Printexc.to_string exn));
  match trajectory_acc with
  | None -> ()
  | Some acc ->
      let trace_id = acc.Trajectory.trace_id in
      let runtime_contract =
        Keeper_tool_call_log.runtime_contract_json_for_call
          ~keeper_name
          ~model
          ()
      in
      let action_radius =
        Keeper_tool_call_log.action_radius_json_for_call
          ~keeper_name
          ~tool_name:event.tool_name
          ~input:safe_input
          ~success:false
          ~duration_ms
          ~error
          ()
      in
      let now = Time_compat.now () in
      let turn = if event.turn > 0 then event.turn else acc.Trajectory.turn in
      let round =
        acc.Trajectory.entries
        |> List.filter (fun (e : Trajectory.tool_call_entry) -> e.turn = turn)
        |> List.length
        |> ( + ) 1
      in
      let entry : Trajectory.tool_call_entry =
        {
          ts = now;
          ts_iso = Masc_domain.iso8601_of_unix_seconds now;
          turn;
          round;
          tool_name = event.tool_name;
          args_json = Yojson.Safe.to_string safe_input;
          gate_decision = Trajectory.Reject error;
          result = Some output_text;
          duration_ms = trajectory_duration_ms duration_ms;
          error = Some error;
          cost_usd = 0.0;
        }
      in
      Trajectory.record_entry
        ~runtime_contract
        ~action_radius
        ~on_persist_error:(fun exn ->
          let dashboard_surface_tool_stats = "/api/v1/keepers/:name/tool-stats" in
          let stale_reason_trajectory_append = "trajectory_append_failed" in
          let telemetry_source_trajectory = "trajectory_tool_call" in
          let telemetry_producer_pre_tool = "keeper_hooks_oas.pre_tool_use" in
          Telemetry_coverage_gap.record
            ~masc_root:acc.Trajectory.masc_root
            ~source:telemetry_source_trajectory
            ~producer:telemetry_producer_pre_tool
            ~durable_store:
              (Trajectory.trajectory_path acc.Trajectory.masc_root
                 acc.Trajectory.keeper_name trace_id)
            ~dashboard_surface:dashboard_surface_tool_stats
            ~stale_reason:stale_reason_trajectory_append
            ~keeper_name
            ~trace_id
            ~exn
            ())
        acc
        entry
