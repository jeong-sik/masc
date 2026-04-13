(** Server_dashboard_http — Dashboard HTTP handlers (facade). *)

include Server_dashboard_http_core
include Server_dashboard_http_runtime_info
include Server_dashboard_http_execution_surfaces
include Server_dashboard_http_namespace_truth
open Types
open Server_utils

(* Wire task mutation hook: invalidate execution cache on any task
   add/transition so the dashboard serves fresh backlog data. *)
let () =
  Room_hooks.on_task_mutation_fn := invalidate_execution_cache


let dashboard_namespace_truth_focus_json =
  Server_dashboard_http_namespace_truth_support.dashboard_namespace_truth_focus_json

let dashboard_namespace_truth_http_json =
  Server_dashboard_http_namespace_truth.dashboard_namespace_truth_http_json

let dashboard_memory_http_json request : Yojson.Safe.t =
  let hearth = query_param request "hearth" in
  let author_filter =
    query_param request "author"
    |> Option.map String.trim
    |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
  in
  let sort_by = board_sort_order_of_request request in
  let exclude_system = bool_query_param request "exclude_system" ~default:false in
  let exclude_automation =
    bool_query_param request "exclude_automation" ~default:false
  in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let base_fetch = board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset in
  let posts =
    Board_dispatch.list_posts ?hearth ~sort_by ~exclude_system
      ~exclude_automation ?author_filter ~limit:base_fetch ()
  in
  let karma_map = Board_dispatch.get_all_karma () in
  let get_karma author =
    Option.value ~default:0 (List.assoc_opt author karma_map)
  in
  let paged = posts |> drop offset |> take limit in
  let posts_json =
    List.map
      (fun (post : Board.post) ->
        let author = Board.Agent_id.to_string post.author in
        board_post_dashboard_json ~author_karma:(get_karma author) post)
      paged
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("visible_posts", `Int (List.length posts_json));
            ("sort_by", `String (board_sort_label sort_by));
            ("exclude_system", `Bool exclude_system);
            ("exclude_automation", `Bool exclude_automation);
          ] );
      ("posts", `List posts_json);
      ("count", `Int (List.length posts_json));
      ("limit", `Int limit);
      ("offset", `Int offset);
      ("sort_by", `String (board_sort_label sort_by));
    ]

let dashboard_memory_subsystems_http_json ~(config : Room_utils.config) request
    : Yojson.Safe.t =
  let limit =
    int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200
  in
  let episodes =
    try Institution_eio.load_recent_episodes_jsonl ~limit
    with _ -> []
  in
  let hebbian =
    try
      let g = Hebbian_eio.load_graph config in
      Hebbian_eio.graph_to_json g
    with _ -> `Assoc [ ("synapses", `List []); ("last_consolidation", `Float 0.0) ]
  in
  let episode_count =
    try
      let path = Institution_eio.episodes_jsonl_path () in
      let jsons = Fs_compat.load_jsonl path in
      List.length jsons
    with _ -> 0
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "hebbian", hebbian );
      ( "episodes",
        `Assoc
          [
            ("total", `Int episode_count);
            ("shown", `Int (List.length episodes));
            ( "items",
              `List
                (List.map Institution_eio.episode_to_json episodes) );
          ] );
    ]

let dashboard_governance_http_json request ~base_path : Yojson.Safe.t =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let status_filter = None in
  ignore (query_param request "status");
  Dashboard_governance.dashboard_json ~base_path ~limit ~offset
    ~status_filter

(** Read the optional [?window=<minutes>] query param.
    Defaults to 60 minutes; clamped to [5..1440]. *)
let dashboard_governance_tool_events_http_json request : Yojson.Safe.t =
  let window =
    int_query_param request "window" ~default:60 |> clamp ~min_v:5 ~max_v:1440
  in
  Dashboard_governance_metrics.governance_tool_events_json
    ~window_minutes:window ()

let dashboard_governance_approval_resolve_http_json ~(args : Yojson.Safe.t) :
    (Yojson.Safe.t, string) result =
  match Safe_ops.json_string_opt "id" args with
  | None ->
      Error "id is required"
  | Some id ->
      let decision_name =
        Safe_ops.json_string_opt "decision" args
        |> Option.value ~default:"approve"
        |> String.trim
        |> String.lowercase_ascii
      in
      let decision =
        match decision_name with
        | "approve" -> Ok Oas.Hooks.Approve
        | "reject" ->
            let reason =
              Safe_ops.json_string_opt "reason" args
              |> Option.value ~default:"dashboard rejected approval"
            in
            Ok (Oas.Hooks.Reject reason)
        | _ ->
            Error "decision must be 'approve' or 'reject'"
      in
      match decision with
      | Error _ as err -> err
      | Ok decision ->
          (match Keeper_approval_queue.resolve ~id ~decision with
           | Ok () ->
               Ok
                 (`Assoc
                   [
                     ("ok", `Bool true);
                     ("id", `String id);
                     ("decision", `String decision_name);
                   ])
           | Error message -> Error message)

let dashboard_planning_http_json ~(config : Room.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let rollup = Goal_store.compute_rollup goals in
  let task_rollup =
    dashboard_tasks_safe config
    |> List.fold_left
         (fun (todo, claimed, running, done_count, cancelled) (task : Types.task) ->
           match task.task_status with
           | Todo -> (todo + 1, claimed, running, done_count, cancelled)
           | Claimed _ -> (todo, claimed + 1, running, done_count, cancelled)
           | InProgress _ -> (todo, claimed, running + 1, done_count, cancelled)
           | Done _ -> (todo, claimed, running, done_count + 1, cancelled)
           | Cancelled _ -> (todo, claimed, running, done_count, cancelled + 1))
         (0, 0, 0, 0, 0)
  in
  let (todo_count, claimed_count, running_count, done_count, cancelled_count) = task_rollup in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("goals", `List (List.map Goal_store.goal_to_yojson goals));
      ("rollup", Goal_store.rollup_to_yojson rollup);
      ( "task_backlog",
        `Assoc
          [
            ("todo", `Int todo_count);
            ("claimed", `Int claimed_count);
            ("in_progress", `Int running_count);
            ("done", `Int done_count);
            ("cancelled", `Int cancelled_count);
          ] );
    ]

let dashboard_goals_tree_http_json ~(config : Room.config) : Yojson.Safe.t =
  Dashboard_goals.dashboard_goals_tree_json ~config

let operator_action_http_json ~state ~sw ~clock request ~args =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      net = state.Mcp_server.net;
      mcp_session_id = None;
    }
  in
  Operator_control.action_json ?actor_hint:(operator_actor_hint request) ctx args

let operator_confirm_http_json ~state ~sw ~clock request ~args =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      net = state.Mcp_server.net;
      mcp_session_id = None;
    }
  in
  Operator_control.confirm_json ?actor_hint:(operator_actor_hint request) ctx args

let operator_error_json message =
  `Assoc [ ("status", `String "error"); ("message", `String message) ]
