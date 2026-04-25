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
  Atomic.set Coord_hooks.on_task_mutation_fn invalidate_execution_cache


let dashboard_namespace_truth_focus_json =
  Server_dashboard_http_namespace_truth_support.dashboard_namespace_truth_focus_json

let dashboard_namespace_truth_http_json =
  Server_dashboard_http_namespace_truth.dashboard_namespace_truth_http_json

let dashboard_board_json ?hearth ?author_filter
    ?(sort_by = Board_dispatch.Hot) ?(exclude_system = false)
    ?(exclude_automation = false) ?(limit = 100) ?(offset = 0) () :
    Yojson.Safe.t =
  let limit = clamp ~min_v:1 ~max_v:500 limit in
  let offset = clamp ~min_v:0 ~max_v:5000 offset in
  let author_filter = Option.map board_actor_author_for_write author_filter in
  let cache_key =
    Printf.sprintf "board:memory:%s;%s;%s;%b;%b;%d;%d"
      (Option.value ~default:"-" hearth)
      (Option.value ~default:"-" author_filter)
      (board_sort_label sort_by)
      exclude_system exclude_automation limit offset
  in
  Dashboard_cache.get_or_compute cache_key ~ttl:10.0 (fun () ->
    let base_fetch = board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset in
    (* Fetch one extra beyond the requested page so we can answer has_more
       without a second query. total is only emitted when the result fits
       entirely inside the fetched window — otherwise null (unknown). *)
    let probe_fetch = base_fetch + 1 in
    let posts =
      Board_dispatch.list_posts ?hearth ~sort_by ~exclude_system
        ~exclude_automation ?author_filter ~limit:probe_fetch ()
    in
    let karma_map = Board_dispatch.get_all_karma () in
    let get_karma author =
      Option.value ~default:0 (List.assoc_opt author karma_map)
    in
    let fetched_len = List.length posts in
    let window_end = offset + limit in
    let has_more = fetched_len > window_end in
    let total_json : Yojson.Safe.t =
      if has_more then `Null else `Int fetched_len
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
        ("has_more", `Bool has_more);
        ("total", total_json);
        ("sort_by", `String (board_sort_label sort_by));
      ])

let dashboard_memory_http_json request : Yojson.Safe.t =
  let hearth = query_param request "hearth" in
  let author_filter =
    query_param request "author"
    |> Option.map String.trim
    |> Fun.flip Option.bind (fun s ->
         if s = "" then None else Some (board_actor_author_for_write s))
  in
  let sort_by = board_sort_order_of_request request in
  let exclude_system = bool_query_param request "exclude_system" ~default:false in
  let exclude_automation =
    bool_query_param request "exclude_automation" ~default:false
  in
  let limit =
    int_query_param request "limit" ~default:100 |> clamp ~min_v:1 ~max_v:500
  in
  let offset =
    int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000
  in
  dashboard_board_json ?hearth ?author_filter ~sort_by ~exclude_system
    ~exclude_automation ~limit ~offset ()

let dashboard_memory_subsystems_http_json ~(config : Coord_utils.config) request
    : Yojson.Safe.t =
  let limit =
    int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:500
  in
  let keeper_filter =
    query_param request "keeper"
    |> Option.map String.trim
    |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
  in
  let outcome_filter =
    query_param request "outcome"
    |> Option.map String.trim
    |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
  in
  let search =
    query_param request "q"
    |> Option.map (fun s -> String.trim s |> String.lowercase_ascii)
    |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
  in
  let hebbian =
    try
      let g = Hebbian_eio.load_graph config in
      Hebbian_eio.graph_to_json g
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> `Assoc [ ("synapses", `List []); ("last_consolidation", `Float 0.0) ]
  in
  let all_episodes =
    try Institution_eio.load_recent_episodes_jsonl ~limit:max_int
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> []
  in
  let total = List.length all_episodes in
  let contains_ci haystack needle =
    let h = String.lowercase_ascii haystack in
    let hlen = String.length h in
    let nlen = String.length needle in
    if nlen = 0 then true
    else if nlen > hlen then false
    else
      let rec scan i =
        if i + nlen > hlen then false
        else if String.sub h i nlen = needle then true
        else scan (i + 1)
      in
      scan 0
  in
  let filtered =
    all_episodes
    |> List.filter (fun (e : Institution_eio.episode) ->
           let keeper_ok =
             match keeper_filter with
             | None -> true
             | Some k -> List.mem k e.participants
           in
           let outcome_ok =
             match outcome_filter with
             | None -> true
             | Some "success" -> e.outcome = `Success
             | Some "failure" -> e.outcome = `Failure
             | Some "partial" -> e.outcome = `Partial
             | Some _ -> true
           in
           let search_ok =
             match search with
             | None -> true
             | Some q ->
               contains_ci e.summary q
               || contains_ci e.event_type q
               || List.exists (fun l -> contains_ci l q) e.learnings
               || List.exists (fun p -> contains_ci p q) e.participants
           in
           keeper_ok && outcome_ok && search_ok)
  in
  let filtered_total = List.length filtered in
  let episodes =
    let rec drop n = function
      | [] -> []
      | rest when n <= 0 -> rest
      | _ :: rest -> drop (n - 1) rest
    in
    if filtered_total <= limit then filtered
    else drop (filtered_total - limit) filtered
  in
  let known_keepers =
    all_episodes
    |> List.concat_map (fun (e : Institution_eio.episode) -> e.participants)
    |> List.sort_uniq String.compare
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "hebbian", hebbian );
      ( "episodes",
        `Assoc
          [
            ("total", `Int total);
            ("filtered", `Int filtered_total);
            ("shown", `Int (List.length episodes));
            ("limit", `Int limit);
            ( "items",
              `List
                (List.map Institution_eio.episode_to_json episodes) );
          ] );
      ( "filters",
        `Assoc
          [
            ( "keepers",
              `List (List.map (fun k -> `String k) known_keepers) );
            ("outcomes", `List [ `String "success"; `String "partial"; `String "failure" ]);
          ] );
    ]

let dashboard_governance_http_json request ~base_path : Yojson.Safe.t =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let status_filter = None in
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

type approval_resolve_http_error =
  | Bad_request of string
  | Gone of Keeper_approval_queue.resolve_error

let approval_resolve_http_error_to_string = function
  | Bad_request msg -> msg
  | Gone err -> Keeper_approval_queue.resolve_error_to_string err

let dashboard_governance_approval_resolve_http_json ~base_path
    ~(args : Yojson.Safe.t) :
    (Yojson.Safe.t, approval_resolve_http_error) result =
  match Safe_ops.json_string_opt "id" args with
  | None ->
      Error (Bad_request "id is required")
  | Some id ->
      let remember_rule =
        Safe_ops.json_bool_opt "remember_rule" args
        |> Option.value ~default:false
      in
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
            Error (Bad_request "decision must be 'approve' or 'reject'")
      in
      match decision with
      | Error _ as err -> err
      | Ok decision ->
          (match
             Keeper_approval_queue.resolve_with_policy ~id ~decision
               ~base_path ~remember_rule ~created_by:"dashboard" ()
           with
           | Ok result ->
               Ok
                 (`Assoc
                   [
                     ("ok", `Bool true);
                     ("id", `String id);
                     ("decision", `String decision_name);
                     ( "rule_id",
                       match result.remembered_rule with
                       | Some rule -> `String rule.id
                       | None -> `Null );
                   ])
           | Error err ->
               Error (Gone err))

let dashboard_governance_approval_rule_delete_http_json ~base_path
    ~(args : Yojson.Safe.t) :
    (Yojson.Safe.t, string) result =
  match Safe_ops.json_string_opt "id" args with
  | None -> Error "id is required"
  | Some id -> (
      match Keeper_approval_queue.delete_rule ~base_path ~id () with
      | Ok deleted ->
          Keeper_approval_queue.audit_rule_event ~base_path ~event_type:"rule_deleted"
            deleted;
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("id", `String deleted.id);
              ])
      | Error message -> Error message)

(* Dashboard-initiated verification verdict. Mirrors the 2-step path that
   tool_task uses for Approve_verification / Reject_verification: first
   transition the task FSM (AwaitingVerification -> Done or InProgress),
   then wire the protocol side effects (Verification store + Board + SSE).

   [verifier] is a namespaced agent_id of the form "operator:<actor>".
   The colon form is permitted by Validation.Agent_id and keeps operator
   verdicts distinguishable from peer-agent verdicts in attribution.

   Decisions are strictly approve | reject — unknown values return
   Bad_request rather than defaulting, per Det/NonDet boundary. *)
let dashboard_verification_resolve_http_json
    ~(config : Coord.config) ~(verifier : string)
    ~(args : Yojson.Safe.t) : (Yojson.Safe.t, string) result =
  let open Result in
  let ( let* ) = bind in
  let* task_id =
    match Safe_ops.json_string_opt "task_id" args with
    | Some s when String.trim s <> "" -> Ok (String.trim s)
    | _ -> Error "task_id is required"
  in
  let* verification_id =
    match Safe_ops.json_string_opt "verification_id" args with
    | Some s when String.trim s <> "" -> Ok (String.trim s)
    | _ -> Error "verification_id is required"
  in
  let decision_name =
    Safe_ops.json_string_opt "decision" args
    |> Option.value ~default:""
    |> String.trim
    |> String.lowercase_ascii
  in
  let reason =
    Safe_ops.json_string_opt "reason" args |> Option.value ~default:""
  in
  let* action =
    match decision_name with
    | "approve" -> Ok Types.Approve_verification
    | "reject"  -> Ok Types.Reject_verification
    | "" -> Error "decision is required (approve | reject)"
    | other ->
        Error (Printf.sprintf
          "decision must be 'approve' or 'reject' (got %s)" other)
  in
  let fsm_result =
    Coord.transition_task_r config
      ~agent_name:verifier ~task_id ~action
      ~notes:reason ~reason ()
  in
  match fsm_result with
  | Error err -> Error (Types.masc_error_to_string err)
  | Ok _ ->
      (match action with
       | Types.Approve_verification ->
           Verification_protocol.on_approve_verification
             ~config ~task_id ~verifier ~verification_id ~notes:reason
       | Types.Reject_verification ->
           Verification_protocol.on_reject_verification
             ~config ~task_id ~verifier ~verification_id ~reason
       | Types.Claim | Types.Start | Types.Done_action | Types.Cancel
       | Types.Release | Types.Submit_for_verification -> ());
      Ok (`Assoc [
        ("ok", `Bool true);
        ("task_id", `String task_id);
        ("verification_id", `String verification_id);
        ("decision", `String decision_name);
        ("verifier", `String verifier);
      ])

let dashboard_planning_http_json ~(config : Coord.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let rollup = Goal_store.compute_rollup goals in
  let task_rollup =
    dashboard_tasks_safe config
    |> List.fold_left
         (fun (todo, claimed, running, done_count, cancelled) (task : Types.task) ->
           match task.task_status with
           | Todo -> (todo + 1, claimed, running, done_count, cancelled)
           | Claimed _ -> (todo, claimed + 1, running, done_count, cancelled)
           | InProgress _ | AwaitingVerification _ -> (todo, claimed, running + 1, done_count, cancelled)
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
      ( "coordination_fsm",
        Coordination_product_snapshot.safe_build_yojson config );
    ]

let dashboard_goals_tree_http_json ~(config : Coord.config) : Yojson.Safe.t =
  Dashboard_goals.dashboard_goals_tree_json ~config

let dashboard_goals_snapshot_json ~(config : Coord.config) : Yojson.Safe.t =
  `Assoc
    [
      ("planning", dashboard_planning_http_json ~config);
      ("tree", dashboard_goals_tree_http_json ~config);
    ]

let dashboard_fleet_composite_json ~(base_path : string) () : Yojson.Safe.t =
  let snapshots = Keeper_composite_observer.all_snapshots ~base_path () in
  `Assoc
    [
      ("generated_at", `Float (Unix.gettimeofday ()));
      ("count", `Int (List.length snapshots));
      ( "snapshots",
        `List (List.map Keeper_composite_observer.snapshot_to_json snapshots)
      );
    ]

let dashboard_goal_detail_http_json ~(config : Coord.config) ~goal_id :
    Yojson.Safe.t =
  match Dashboard_goals.goal_detail_json ~config ~goal_id with
  | Ok json -> json
  | Error message ->
      `Assoc
        [
          ("ok", `Bool false);
          ("error", `String message);
          ("goal_id", `String goal_id);
        ]

let operator_action_http_json ~state ~sw ~clock request ~args =
  let actor =
    Server_auth.dashboard_actor_for_request
      ~base_path:state.Mcp_server.room_config.base_path
      request
  in
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" actor;
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      net = state.Mcp_server.net;
      mcp_session_id = None;
    }
  in
  Operator_control.action_json ?actor_hint:actor ctx args

let operator_confirm_http_json ~state ~sw ~clock request ~args =
  let actor =
    Server_auth.dashboard_actor_for_request
      ~base_path:state.Mcp_server.room_config.base_path
      request
  in
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" actor;
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      net = state.Mcp_server.net;
      mcp_session_id = None;
    }
  in
  Operator_control.confirm_json ?actor_hint:actor ctx args

let operator_error_json message =
  `Assoc [ ("status", `String "error"); ("message", `String message) ]
