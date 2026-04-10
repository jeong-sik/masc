
open Swarm_status_types
open Swarm_status_json
open Swarm_status_classify

let slice_by_kind kind classify rows =
  List.filter (fun row -> classify row = kind) rows

let lane_present kind ~operations ~detachments ~alerts ~decisions ~traces ~sessions =
  match kind with
  | Managed ->
      (* Managed lanes should reflect live command-plane runtime, not historical
         trace residue. Current managed alerts are recomputed from snapshot state
         and must keep the lane visible, but old traces alone should not keep it
         present forever and surface stale_data as if work were still in flight. *)
      List.exists operation_active operations
      || List.exists detachment_active detachments
      || List.exists decision_pending decisions
      || alerts <> []
  | Supervised ->
      (* Supervised traces are historical. Only live session/runtime artifacts should
         make the lane present, otherwise stale operator/team-session traces create a
         phantom supervised lane after the real session has already ended. *)
      operations <> [] || detachments <> [] || decisions <> [] || sessions <> []
  | Projected ->
      operations <> [] || detachments <> [] || alerts <> [] || decisions <> [] || traces <> []
      || sessions <> []

let lane_for_kind kind ~now ~operations ~detachments ~alerts ~decisions ~traces
    ~sessions ~mixed_runtime_sources =
  let workers =
    match kind with
    | Supervised ->
        sessions |> List.concat_map (fun (session : session_info) -> session.worker_names)
        |> unique_strings |> List.length
    | Managed | Projected ->
        worker_names_from_detachments detachments |> List.length
  in
  let present = lane_present kind ~operations ~detachments ~alerts ~decisions ~traces ~sessions in
  let approvals =
    decisions
    |> List.filter (fun (decision : decision_info) -> String.equal decision.status "pending")
    |> List.length
  in
  let alerts_count = List.length alerts in
  let terminal =
    present
    && operations <> []
    && List.for_all operation_terminal operations
    && approvals = 0
  in
  let active_operations =
    operations |> List.filter operation_active |> List.length
  in
  let last_movement, movement_reason =
    match lane_last_movement traces decisions detachments operations sessions with
    | Some (timestamp, reason) -> (Some timestamp, reason)
    | None ->
        if not present then
          (None, "no_active_data")
        else
          (None, "missing_runtime_progress")
  in
  let motion_state =
    lane_motion_state now ~present ~phase:"" ~last_movement_at:last_movement ~approvals
  in
  let phase =
    lane_phase ~present ~active_operations ~detachments:(List.length detachments)
      ~workers ~approvals ~motion_state ~terminal
  in
  let flags =
    lane_flags kind ~present ~approvals ~workers ~trace_count:(List.length traces)
      ~last_movement_at:last_movement ~mixed_runtime_sources
  in
  let blockers =
    lane_blockers kind ~phase ~motion_state ~approvals ~workers ~flags
  in
  let current_step =
    lane_current_step kind ~present ~phase ~motion_state ~approvals
      ~detachments:(List.length detachments) ~workers
  in
  {
    lane_id = lane_id kind;
    label = lane_label kind;
    kind = lane_kind_string kind;
    present;
    phase;
    motion_state;
    source_of_truth = source_of_truth kind;
    last_movement_at = last_movement;
    movement_reason;
    current_step;
    blockers;
    operations = List.length operations;
    detachments = List.length detachments;
    workers;
    approvals;
    alerts = alerts_count;
    hard_flags = flags;
  }

let choose_recommendation lanes =
  let find_lane lane_id =
    List.find_opt (fun (lane : lane) -> String.equal lane.lane_id lane_id) lanes
  in
  let has_flag lane code =
    List.exists (fun (flag : flag) -> String.equal flag.code code) lane.hard_flags
  in
  match List.find_opt (fun (lane : lane) -> has_flag lane "pending_manual_confirmation") lanes with
  | Some lane when String.equal lane.lane_id "managed" ->
      {
        tool = "masc_policy_approve";
        label = "Resolve pending approval";
        reason = "A managed command-plane decision is blocking progress.";
        lane_id = Some lane.lane_id;
      }
  | Some lane ->
      {
        tool = "masc_operator_confirm";
        label = "Confirm the pending action";
        reason = "A supervised operator action is still waiting for confirmation.";
        lane_id = Some lane.lane_id;
      }
  | None -> (
      match
        List.find_opt
          (fun (lane : lane) ->
            String.equal lane.lane_id "managed"
            && lane.present && lane.detachments = 0 && lane.operations > 0)
          lanes
      with
      | Some lane ->
          {
            tool = "masc_dispatch_tick";
            label = "Materialize detachments";
            reason = "Managed operations exist, but detachments have not been reconciled yet.";
            lane_id = Some lane.lane_id;
          }
      | None -> (
          match
            List.find_opt
              (fun (lane : lane) ->
                String.equal lane.lane_id "managed" && has_flag lane "stale_data")
              lanes
          with
          | Some lane ->
              {
                tool = "masc_dispatch_tick";
                label = "Reconcile the managed lane";
                reason = "The managed lane is stale and needs a dispatch tick or trace check.";
                lane_id = Some lane.lane_id;
              }
          | None -> (
              match
                List.find_opt
                  (fun (lane : lane) ->
                    String.equal lane.lane_id "supervised"
                    && has_flag lane "stale_data")
                  lanes
              with
              | Some lane ->
                  {
                    tool = "masc_operator_snapshot";
                    label = "Inspect the supervised session";
                    reason = "The supervised lane is stale and needs a status check.";
                    lane_id = Some lane.lane_id;
                  }
              | None -> (
                  match
                    ( find_lane "projected",
                      find_lane "managed",
                      find_lane "supervised" )
                  with
                  | Some projected, Some managed, _
                    when projected.present && not managed.present ->
                      {
                        tool = "masc_operation_start";
                        label = "Convert projection into runtime";
                        reason = "Projected swarm state exists without a managed operation.";
                        lane_id = Some projected.lane_id;
                      }
                  | Some projected, _, Some supervised
                    when projected.present && not supervised.present ->
                      {
                        tool = "masc_operator_snapshot";
                        label = "Inspect projected state";
                        reason = "Projected swarm state exists without a supervised session.";
                        lane_id = Some projected.lane_id;
                      }
                  | _ ->
                      {
                        tool = "masc_observe_traces";
                        label = "Observe recent movement";
                        reason = "The swarm is moving; trace review is the next high-signal step.";
                        lane_id = None;
                      }))))
