(** Command_plane_orchestra — CP graph JSON assembly.

    Facade module: re-exports sub-modules and provides the [json] assembly
    function that combines all graph nodes, edges, and signals.

    Implementation split into:
    - {!Cp_orchestra_helpers} — JSON utilities, node/edge/signal builders
    - {!Cp_orchestra_nodes} — entity-specific node renderers

    @since God file decomposition *)

include Cp_orchestra_helpers
include Cp_orchestra_nodes

let string_assoc_list json =
  match json with
  | `Assoc fields -> fields
  | _ -> []

let json_assoc_of_fields fields = `Assoc fields

let by_id rows key_field =
  rows
  |> List.filter_map (fun row ->
         match string_opt row key_field with
         | Some key -> Some (key, row)
         | None -> None)

let json ?run_id:_ ?operation_id:_ (ctx : _ Operator_control.context) =
  let config = ctx.config in
  let actor = ctx.agent_name in
  let namespace = namespace_json config in
  let namespace_id =
    "namespace:" ^ (string_opt namespace "namespace" |> Option.value ~default:"default")
  in
  let operator_snapshot = Operator_control.snapshot_json ~actor ctx in
  let pending_summary =
    assoc_or_empty operator_snapshot "pending_confirm_summary"
  in
  let keepers =
    list_member (assoc_or_empty operator_snapshot "keepers") "items"
    @ list_member (assoc_or_empty operator_snapshot "persistent_agents") "items"
  in
  let sessions = [] in
  let summary_json = Command_plane_v2.summary_json config in
  let alerts_json = Command_plane_v2.list_alerts_json config in
  let alerts = list_member alerts_json "alerts" in
  let swarm_status_json =
    if Room.is_initialized config then
      Swarm_status.build_json config
    else
      Swarm_status.empty_json
  in
  let swarm_json = `Assoc [] in
  let operations_json = Command_plane_v2.operation_status_json config () in
  let operation_rows =
    list_member operations_json "operations"
    |> List.filter_map (fun row ->
           match U.member "operation" row with
           | `Assoc _ as op -> Some op
           | _ -> None)
  in
  let active_operation_rows =
    operation_rows
    |> List.filter (fun op ->
           let status = string_opt op "status" |> Option.value ~default:"active" |> Dashboard_utils.session_lifecycle_of_string in
           not (Dashboard_utils.is_session_terminal status))
  in
  let detachments_json = Command_plane_v2.list_detachments_json config in
  let detachment_rows =
    list_member detachments_json "detachments"
    |> List.filter_map (fun row ->
           match U.member "detachment" row with
           | `Assoc _ as det -> Some det
           | _ -> None)
  in
  let active_detachment_rows =
    detachment_rows
    |> List.filter (fun det ->
           let status = string_opt det "status" |> Option.value ~default:"active" |> Dashboard_utils.session_lifecycle_of_string in
           not (Dashboard_utils.is_session_terminal status))
  in
  let swarm_workers = list_member swarm_json "workers" in
  let actual_worker_names =
    swarm_workers
    |> List.filter_map (fun row -> string_opt row "name")
  in
  let _actual_worker_name_set = actual_worker_names |> List.sort_uniq String.compare in
  let worker_lanes =
    swarm_workers
    |> List.fold_left
         (fun acc row ->
           let lane = string_opt row "lane" |> Option.value ~default:"swarm" in
           let existing = List.assoc_opt lane acc |> Option.value ~default:[] in
           (lane, row :: existing) :: List.remove_assoc lane acc)
         []
    |> List.map (fun (lane, rows) -> (lane, List.rev rows))
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  in
  (* Team sessions removed — session_nodes always empty *)
  let session_nodes = [] in
  ignore sessions;
  let operation_nodes = List.map operation_node active_operation_rows in
  let detachment_nodes = List.map detachment_node active_detachment_rows in
  let lane_nodes =
    if worker_lanes <> [] then
      List.map (fun (lane_name, rows) -> lane_group_node lane_name rows) worker_lanes
    else
      list_member swarm_status_json "lanes"
      |> List.filter (fun row -> bool_opt row "present" |> Option.value ~default:false)
      |> List.map control_lane_node
  in
  let actual_worker_nodes = List.map actual_worker_node swarm_workers in
  (* ghost_worker_nodes from sessions removed — sessions always [] *)
  let ghost_worker_nodes = [] in
  let keeper_nodes = List.map keeper_node keepers in
  let nodes =
    namespace_node namespace (List.length sessions) (List.length active_operation_rows)
      (List.length actual_worker_nodes + List.length ghost_worker_nodes)
      (List.length keeper_nodes) (List.length alerts)
      (int_opt pending_summary "total_count" |> Option.value ~default:0)
    :: session_nodes @ operation_nodes @ detachment_nodes @ lane_nodes
       @ actual_worker_nodes @ ghost_worker_nodes @ keeper_nodes
  in
  let operation_rows_by_id = by_id active_operation_rows "operation_id" in
  let detachment_rows_by_id = by_id active_detachment_rows "detachment_id" in
  let edges =
    (* Session edges removed — sessions always [] *)
    (active_detachment_rows
      |> List.filter_map (fun det ->
             match string_opt det "operation_id" with
             | Some operation_id
               when List.mem_assoc operation_id operation_rows_by_id ->
                 let detachment_id =
                   string_opt det "detachment_id" |> Option.value ~default:"detachment"
                 in
                 Some
                   (edge
                      ~id:("edge:operation-detachment:" ^ operation_id ^ ":" ^ detachment_id)
                      ~source:("operation:" ^ operation_id)
                      ~target:("detachment:" ^ detachment_id) ~kind:"materializes"
                      ~label:"detachment" ~provenance:"truth" ())
             | _ -> None))
    @ (if worker_lanes <> [] then
         let lane_parent =
           match string_opt (assoc_or_empty swarm_json "detachment") "detachment_id" with
           | Some detachment_id when List.mem_assoc detachment_id detachment_rows_by_id ->
               "detachment:" ^ detachment_id
           | _ -> (
               match string_opt (assoc_or_empty swarm_json "operation") "operation_id" with
               | Some operation_id when List.mem_assoc operation_id operation_rows_by_id ->
                   "operation:" ^ operation_id
               | _ -> namespace_id)
         in
         (worker_lanes
         |> List.map (fun (lane_name, _rows) ->
                edge ~id:("edge:parent-lane:" ^ lane_name) ~source:lane_parent
                  ~target:("lane:" ^ lane_name) ~kind:"routes"
                  ~label:"lane" ~tone:"ok" ~animated:true ~provenance:"truth"
                  ()))
         @ (worker_lanes
           |> List.concat_map (fun (lane_name, rows) ->
                  rows
                  |> List.filter_map (fun row ->
                         match string_opt row "name" with
                         | Some name ->
                             Some
                               (edge
                                  ~id:("edge:lane-worker:" ^ lane_name ^ ":" ^ name)
                                  ~source:("lane:" ^ lane_name)
                                  ~target:("worker:" ^ name) ~kind:"feeds"
                                  ~label:"worker" ~animated:true
                                  ~provenance:"truth" ())
                         | None -> None)))
       else
         [])
    @ (ghost_worker_nodes
      |> List.filter_map (fun node_json ->
             match string_opt node_json "id", string_opt node_json "parent_id" with
             | Some worker_id, Some parent_id ->
                 Some
                   (edge ~id:("edge:session-ghost:" ^ worker_id) ~source:parent_id
                      ~target:worker_id ~kind:"planned" ~label:"planned worker"
                      ~tone:"warn" ~animated:false ~provenance:"derived" ())
             | _ -> None))
    @ (keeper_nodes
      |> List.filter_map (fun keeper_json ->
             match string_opt keeper_json "id" with
             | Some keeper_id ->
                 Some
                   (edge ~id:("edge:namespace-keeper:" ^ keeper_id)
                      ~source:namespace_id ~target:keeper_id ~kind:"continuity"
                      ~label:"keeper" ~provenance:"truth" ())
             | None -> None))
  in
  let signals =
    List.filter_map Fun.id
      [
        signal_for_pending_confirms pending_summary namespace_id;
        signal_for_runtime_blocker swarm_json namespace_id;
        signal_for_hot_proof summary_json namespace_id;
      ]
    @ signals_for_alerts alerts namespace_id
  in
  let focus =
    match List.find_opt (fun signal_json -> string_opt signal_json "tone" = Some "bad") signals with
    | Some signal_json ->
        `Assoc
          [
            ("target_kind", `String "signal");
            ( "target_id",
              `String
                (string_opt signal_json "id"
                |> Option.value ~default:"signal:unknown") );
            ( "label",
              `String
                (string_opt signal_json "label"
                |> Option.value ~default:"Signal") );
            ( "reason",
              `String
                (string_opt signal_json "detail"
                |> Option.value ~default:"Critical orchestra signal") );
            ( "suggested_surface",
              json_string_option (string_opt signal_json "suggested_surface") );
            ("suggested_params", assoc_or_empty signal_json "suggested_params");
          ]
    | None -> (
        match
          List.find_opt
            (fun node_json ->
              string_opt node_json "kind" = Some "session"
              && string_opt node_json "tone" <> Some "ok")
            nodes
        with
        | Some node_json ->
            `Assoc
              [
                ("target_kind", `String "node");
                ( "target_id",
                  `String
                    (string_opt node_json "id"
                    |> Option.value ~default:namespace_id) );
                ("label", `String (string_opt node_json "label" |> Option.value ~default:"session"));
                ("reason", `String "A session needs supervision or is not fully healthy.");
                ("suggested_surface", `String "intervene");
                ("suggested_params", assoc_or_empty node_json "link_params");
              ]
        | None ->
            `Assoc
              [
                ("target_kind", `String "node");
                ("target_id", `String namespace_id);
                ( "label",
                  `String
                    (string_opt namespace "namespace" |> Option.value ~default:"default") );
                ( "reason",
                  `String
                    "Namespace-wide view is healthy enough; start from the command overview."
                );
                ("suggested_surface", `String "summary");
                ("suggested_params", `Assoc []);
              ])
  in
  `Assoc
    [
      ("version", `String "orchestra.v1");
      ("generated_at", `String (Types.now_iso ()));
      ("namespace", namespace);
      ( "summary",
        `Assoc
          [
            ("session_count", `Int (List.length sessions));
            ("operation_count", `Int (List.length active_operation_rows));
            ("detachment_count", `Int (List.length active_detachment_rows));
            ("lane_count", `Int (List.length lane_nodes));
            ( "worker_count",
              `Int (List.length actual_worker_nodes + List.length ghost_worker_nodes) );
            ("keeper_count", `Int (List.length keeper_nodes));
            ("signal_count", `Int (List.length signals));
            ("alert_count", `Int (List.length alerts));
          ] );
      ("nodes", `List nodes);
      ("edges", `List edges);
      ("signals", `List signals);
      ("focus", focus);
      ("swarm_status", swarm_status_json);
      ("swarm_proof", assoc_or_empty summary_json "swarm_proof");
      ( "truth_notes",
        `List
          [
            `String
              "namespace-wide orchestra map is composed from command-plane truth, swarm live state, and operator read models.";
            `String
              "provenance marks whether a node or signal is truth, derived, or fallback.";
          ] );
    ]
