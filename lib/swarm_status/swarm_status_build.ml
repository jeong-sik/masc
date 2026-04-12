
open Swarm_status_types
open Swarm_status_json
open Swarm_status_classify
open Swarm_status_lanes

(* Tail-recursive List.concat_map — avoids Stack_overflow on long
   lane event lists.  Stdlib's version uses O(N) stack frames. *)
let concat_map_safe f l =
  List.rev (List.fold_left (fun acc x -> List.rev_append (f x) acc) [] l)

let build_json_from_inputs ~timeline_limit_override ~now
    ~operations ~detachments ~alerts ~decisions ~traces ~sessions =
  let operation_kinds =
    operations
    |> List.map (fun (operation : operation_info) ->
           (operation.operation_id, classify_operation operation))
  in
  let detachment_kinds =
    detachments
    |> List.map (fun (detachment : detachment_info) ->
           ( detachment.detachment_id,
             classify_detachment operation_kinds detachment ))
  in
  let mixed_runtime_sources =
    let has_managed =
      List.exists (fun (operation : operation_info) -> classify_operation operation = Managed) operations
      || List.exists
           (fun (detachment : detachment_info) ->
             classify_detachment operation_kinds detachment = Managed)
           detachments
    in
    let has_projected =
      List.exists (fun (operation : operation_info) -> classify_operation operation = Projected) operations
      || List.exists
           (fun (detachment : detachment_info) ->
             classify_detachment operation_kinds detachment = Projected)
           detachments
    in
    has_managed && has_projected
  in
  let alerts_by_kind kind =
    slice_by_kind kind (classify_alert operation_kinds detachment_kinds) alerts
  in
  let decisions_by_kind kind =
    slice_by_kind kind (classify_decision operation_kinds) decisions
  in
  let traces_by_kind kind =
    slice_by_kind kind (classify_trace operation_kinds) traces
  in
  let lanes =
    [ Managed; Supervised; Projected ]
    |> List.map (fun kind ->
           let lane_operations =
             slice_by_kind kind classify_operation operations
             |> (match kind with
                | Supervised -> List.filter operation_active
                | Managed | Projected -> Fun.id)
           in
           let lane_detachments =
             slice_by_kind kind (classify_detachment operation_kinds) detachments
             |> (match kind with
                | Supervised -> List.filter detachment_active
                | Managed | Projected -> Fun.id)
           in
           let lane_decisions =
             decisions_by_kind kind
             |> (match kind with
                | Supervised -> List.filter decision_pending
                | Managed | Projected -> Fun.id)
           in
           let lane_sessions =
             match kind with
             | Supervised -> List.filter session_active sessions
             | Managed | Projected -> []
           in
           lane_for_kind kind ~now ~operations:lane_operations
             ~detachments:lane_detachments ~alerts:(alerts_by_kind kind)
             ~decisions:lane_decisions ~traces:(traces_by_kind kind)
             ~sessions:lane_sessions ~mixed_runtime_sources)
  in
  let timeline =
    let projected_events =
      match
        projected_refresh_event
          (slice_by_kind Projected classify_operation operations)
          (slice_by_kind Projected (classify_detachment operation_kinds) detachments)
      with
      | Some event -> [ event ]
      | None -> []
    in
    let lane_events =
      lanes
      |> List.sort (fun (left : lane) (right : lane) ->
             Int.compare
               (lane_kind_order
                  (match left.lane_id with
                  | "managed" -> Managed
                  | "supervised" -> Supervised
                  | _ -> Projected))
               (lane_kind_order
                  (match right.lane_id with
                  | "managed" -> Managed
                  | "supervised" -> Supervised
                  | _ -> Projected)))
      |> concat_map_safe (fun (lane : lane) ->
             let kind =
               match lane.lane_id with
               | "managed" -> Managed
               | "supervised" -> Supervised
               | _ -> Projected
             in
             lane_timeline_events kind
               (traces_by_kind kind)
               (if kind = Supervised then sessions else [])
               (decisions_by_kind kind))
    in
    (projected_events @ lane_events)
    |> List.filter_map (fun (event : timeline_event) ->
           match parse_iso_timestamp event.timestamp with
           | Some ts -> Some (ts, event)
           | None -> None)
    |> List.sort (fun (left, _) (right, _) -> Float.compare right left)
    |> List.filteri (fun idx _ -> idx < timeline_limit_override)
    |> List.map snd
  in
  let gap_groups =
    let grouped = Hashtbl.create 16 in
    List.iter
      (fun (lane : lane) ->
        List.iter
          (fun (flag : flag) ->
            let key = flag.code in
            let existing =
              match Hashtbl.find_opt grouped key with
              | Some value -> value
              | None -> (flag, [])
            in
            let group_flag, lane_ids = existing in
            Hashtbl.replace grouped key (group_flag, lane.lane_id :: lane_ids))
          lane.hard_flags)
      lanes;
    grouped
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.map (fun (_, (flag, lane_ids)) ->
           let lane_ids = lane_ids |> List.rev |> List.sort_uniq String.compare in
           let why_it_matters, next_tool, next_step =
             gap_guidance ~lane_ids flag.code
           in
           `Assoc
             [
               ("code", `String flag.code);
               ("severity", `String flag.severity);
               ("summary", `String flag.summary);
               ("why_it_matters", `String why_it_matters);
               ("next_tool", `String next_tool);
               ("next_step", `String next_step);
               ("lane_ids", `List (List.map (fun lane_id -> `String lane_id) lane_ids));
               ("count", `Int (List.length lane_ids));
               ("provenance", `String "derived");
             ])
    |> List.sort (fun left right ->
           let left_severity = match U.member "severity" left with `String s -> s | _ -> "unknown" in
           let right_severity = match U.member "severity" right with `String s -> s | _ -> "unknown" in
           Int.compare (severity_sort left_severity) (severity_sort right_severity))
  in
  let present_lanes = List.filter (fun (lane : lane) -> lane.present) lanes in
  let moving_lanes =
    List.length
      (List.filter (fun (lane : lane) -> String.equal lane.motion_state "moving") lanes)
  in
  let stalled_lanes =
    List.length
      (List.filter (fun (lane : lane) -> String.equal lane.motion_state "stalled") lanes)
  in
  let projected_lanes =
    List.length
      (List.filter (fun (lane : lane) -> String.equal lane.kind "projected" && lane.present) lanes)
  in
  let last_movement_at =
    lanes
    |> List.filter_map (fun (lane : lane) ->
           match lane.last_movement_at with
           | Some timestamp -> (
               match parse_iso_timestamp timestamp with
               | Some ts -> Some (ts, timestamp)
               | None -> None)
           | None -> None)
    |> List.sort (fun (left, _) (right, _) -> Float.compare right left)
    |> function
    | (_, timestamp) :: _ -> Some timestamp
    | [] -> None
  in
  let recommendation = choose_recommendation lanes in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("judgment_owner", `String "fallback_read_model");
      ("authoritative_judgment_available", `Bool false);
      ("provenance_summary", swarm_surface_contract_json);
      ("narrative", narrative_json lanes timeline recommendation);
      ( "overview",
        let total_workers = List.fold_left (fun acc (lane : lane) -> acc + lane.workers) 0 present_lanes in
        let has_bad_flags = List.exists lane_has_bad_flag present_lanes in
        `Assoc
          [
            ("active_lanes", `Int (List.length present_lanes));
            ("moving_lanes", `Int moving_lanes);
            ("stalled_lanes", `Int stalled_lanes);
            ("projected_lanes", `Int projected_lanes);
            ("total_workers", `Int total_workers);
            ("has_failure", `Bool has_bad_flags);
            ("last_movement_at", string_option_to_json last_movement_at);
            ("provenance", `String "derived");
          ] );
      ("lanes", `List (List.map lane_to_json lanes));
      ("timeline", `List (List.map timeline_event_to_json timeline));
      ( "gaps",
        `Assoc
          [
            ("count", `Int (List.length gap_groups));
            ("items", `List gap_groups);
          ] );
      ("recommended_next_action", recommendation_to_json recommendation);
    ]

let empty_json =
  let lane kind =
    {
      lane_id = lane_id kind;
      label = lane_label kind;
      kind = lane_kind_string kind;
      present = false;
      phase = "forming";
      motion_state = "waiting";
      source_of_truth = source_of_truth kind;
      last_movement_at = None;
      movement_reason = "no_active_data";
      current_step = lane_current_step kind ~present:false ~phase:"forming"
          ~motion_state:"waiting" ~approvals:0 ~detachments:0 ~workers:0;
      blockers = [];
      operations = 0;
      detachments = 0;
      workers = 0;
      approvals = 0;
      alerts = 0;
      hard_flags = [];
    }
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("judgment_owner", `String "fallback_read_model");
      ("authoritative_judgment_available", `Bool false);
      ("provenance_summary", swarm_surface_contract_json);
      ( "narrative",
        `Assoc
          [
            ("state", `String "idle");
            ("started", `String "No visible swarm start signal is recorded yet.");
            ("active_work", `String "No active swarm lane is visible yet.");
            ("completion", `String "No completion evidence is visible yet.");
            ("lane_id", `Null);
          ] );
      ( "overview",
        `Assoc
          [
            ("active_lanes", `Int 0);
            ("moving_lanes", `Int 0);
            ("stalled_lanes", `Int 0);
            ("projected_lanes", `Int 0);
            ("total_workers", `Int 0);
            ("has_failure", `Bool false);
            ("last_movement_at", `Null);
            ("provenance", `String "derived");
          ] );
      ("lanes", `List (List.map lane_to_json [ lane Managed; lane Supervised; lane Projected ]));
      ("timeline", `List []);
      ("gaps", `Assoc [ ("count", `Int 0); ("items", `List []) ]);
      ( "recommended_next_action",
        recommendation_to_json
          {
            tool = "masc_operator_snapshot";
            label = "Read operator state";
            reason = "No active swarm lane is visible yet.";
            lane_id = None;
          } );
    ]
