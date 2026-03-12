(** MASC MCP Server - Eio Native Entry Point
    MCP Streamable HTTP Transport with Eio concurrency (OCaml 5.x)

    Uses h2-eio for HTTP/2 with unlimited SSE streams per connection.
    HTTP/2 multiplexing eliminates browser's 6-connection-per-domain limit.
*)

[@@@warning "-32-69"]  (* Suppress unused values/fields during migration *)

open Cmdliner

(** Module aliases *)
module Http = Masc_mcp.Http_server_eio
module Http_h2 = Masc_mcp.Http_server_h2
module Mcp_session = Masc_mcp.Mcp_session
module Mcp_server = Masc_mcp.Mcp_server
module Mcp_eio = Masc_mcp.Mcp_server_eio
module Room = Masc_mcp.Room
module Room_utils = Masc_mcp.Room_utils
module Tool_keeper = Masc_mcp.Tool_keeper
module Tool_operator = Masc_mcp.Tool_operator
module Operator_control = Masc_mcp.Operator_control
module Command_plane_v2 = Masc_mcp.Command_plane_v2
module Dashboard_execution = Masc_mcp.Dashboard_execution
module Dashboard_mission = Masc_mcp.Dashboard_mission
module Dashboard_proof = Masc_mcp.Dashboard_proof
module Dashboard_mission_briefing = Masc_mcp.Dashboard_mission_briefing
module Build_identity = Masc_mcp.Build_identity
module Tool_audit = Masc_mcp.Tool_audit
module Graphql_api = Masc_mcp.Graphql_api
module Types = Masc_mcp.Types
module Tempo = Masc_mcp.Tempo
module Auth = Masc_mcp.Auth
module Board = Masc_mcp.Board
module Board_dispatch = Masc_mcp.Board_dispatch
module Board_listener = Masc_mcp.Board_listener
module Council = Masc_mcp.Council
module Task_dispatch = Masc_mcp.Task_dispatch
module Http_negotiation = Masc_mcp.Mcp_protocol.Http_negotiation
module Progress = Masc_mcp.Progress
module Sse = Masc_mcp.Sse
module Safe_ops = Masc_mcp.Safe_ops
module Context_manager = Masc_mcp.Context_manager
module Llm_client = Masc_mcp.Llm_client
module Tool_perpetual = Masc_mcp.Tool_perpetual
module Tool_mdal = Masc_mcp.Tool_mdal
module Tool_board = Masc_mcp.Tool_board
module Process_eio = Masc_mcp.Process_eio
module Mdal = Masc_mcp.Mdal
module Server_command_plane_http = Masc_mcp.Server_command_plane_http
module Server_mcp_transport_http = Masc_mcp.Server_mcp_transport_http

(** MCP Protocol Versions *)
let mcp_protocol_versions = Server_mcp_transport_http.mcp_protocol_versions

let mcp_protocol_version_default =
  Server_mcp_transport_http.mcp_protocol_version_default

let default_base_path = Server_mcp_transport_http.default_base_path

let is_valid_protocol_version =
  Server_mcp_transport_http.is_valid_protocol_version

let remember_protocol_version =
  Server_mcp_transport_http.remember_protocol_version

let remember_mcp_profile = Server_mcp_transport_http.remember_mcp_profile

let forget_mcp_session = Server_mcp_transport_http.forget_mcp_session

let validate_mcp_session_profile =
  Server_mcp_transport_http.validate_mcp_session_profile

let validate_mcp_session_delete_profile =
  Server_mcp_transport_http.validate_mcp_session_delete_profile

let protocol_version_from_body =
  Server_mcp_transport_http.protocol_version_from_body

let get_session_id_query = Server_mcp_transport_http.get_session_id_query

let get_header_any_case = Server_mcp_transport_http.get_header_any_case

let get_cookie_value = Server_mcp_transport_http.get_cookie_value

let get_session_id_any = Server_mcp_transport_http.get_session_id_any

let legacy_messages_endpoint_url =
  Server_mcp_transport_http.legacy_messages_endpoint_url

let get_protocol_version = Server_mcp_transport_http.get_protocol_version

let get_protocol_version_for_session =
  Server_mcp_transport_http.get_protocol_version_for_session

(* ============================================ *)
(* Extracted modules (lib/)                      *)
(* ============================================ *)
include Masc_mcp.Server_utils
include Masc_mcp.Server_auth
include Masc_mcp.Server_tts_proxy
include Masc_mcp.Server_trpg_rest
include Masc_mcp.Server_dashboard_http
let operator_actor_hint request =
  match agent_from_request request with
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let operator_snapshot_http_json ~state ~sw ~clock request =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  let include_messages =
    match query_param request "include_messages" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  let include_sessions =
    match query_param request "include_sessions" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  let include_keepers =
    match query_param request "include_keepers" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  Operator_control.snapshot_json ?actor:(operator_actor_hint request)
    ~include_messages ~include_sessions ~include_keepers ctx

let operator_digest_http_json ~state ~sw ~clock request =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  let target_type = query_param request "target_type" in
  let target_id = query_param request "target_id" in
  let include_workers =
    match query_param request "include_workers" with
    | Some ("0" | "false" | "no") -> Some false
    | Some ("1" | "true" | "yes") -> Some true
    | _ -> None
  in
  Operator_control.digest_json ?actor:(operator_actor_hint request)
    ?target_type ?target_id ?include_workers ctx

let dashboard_mission_http_json ~state ~sw ~clock request =
  Dashboard_mission.json ?actor:(operator_actor_hint request)
    ~config:state.Mcp_server.room_config ~sw ~clock
    ~proc_mgr:state.Mcp_server.proc_mgr ()

let dashboard_mission_briefing_http_json ~state ~sw ~clock request =
  Dashboard_mission_briefing.json ?actor:(operator_actor_hint request)
    ~force:(bool_query_param request "force" ~default:false)
    ~config:state.Mcp_server.room_config ~sw ~clock
    ~proc_mgr:state.Mcp_server.proc_mgr ()

let dashboard_proof_http_json ~state request =
  let session_id = query_param request "session_id" in
  let operation_id = query_param request "operation_id" in
  Dashboard_proof.json ?actor:(operator_actor_hint request) ?session_id
    ?operation_id ~config:state.Mcp_server.room_config ()

let dashboard_shell_status_json (config : Room.config) : Yojson.Safe.t =
  let room_state = Room.read_state config in
  let tempo = Tempo.get_tempo config in
  let lodge_json = Masc_mcp.Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let build = Build_identity.current () in
  `Assoc
    [
      ("room", `String room_state.project);
      ("room_base_path", `String config.base_path);
      ( "cluster",
        `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME"))
      );
      ("project", `String room_state.project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool room_state.paused);
      ("lodge", lodge_json);
      ("version", `String build.release_version);
      ("build", Build_identity.to_yojson build);
    ]

let dashboard_task_assignee (task : Types.task) =
  match task.task_status with
  | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
      Some assignee
  | Todo | Cancelled _ -> None

let dashboard_task_json (task : Types.task) =
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("description", `String task.description);
      ("status", `String (Types.string_of_task_status task.task_status));
      ("priority", `Int task.priority);
      ("assignee", match dashboard_task_assignee task with Some v -> `String v | None -> `Null);
      ("created_at", `String task.created_at);
    ]

let dashboard_agent_json (agent : Types.agent) =
  let (emoji, korean_name) = get_agent_identity agent.name in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Types.string_of_agent_status agent.status));
      ("current_task", match agent.current_task with Some task -> `String task | None -> `Null);
      ("joined_at", `String agent.joined_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun item -> `String item) agent.capabilities));
      ("emoji", `String emoji);
      ("koreanName", `String korean_name);
    ]

let dashboard_message_json (message : Types.message) =
  `Assoc
    [
      ("from", `String message.from_agent);
      ("content", `String message.content);
      ("timestamp", `String message.timestamp);
      ("seq", `Int message.seq);
    ]

let json_list_field key json =
  match Yojson.Safe.Util.member key json with
  | `List items -> items
  | _ -> []

let json_int_field key json ~default =
  match Yojson.Safe.Util.member key json with
  | `Int value -> value
  | `Intlit raw -> (try int_of_string raw with Failure _ -> default)
  | _ -> default

let dashboard_current_room_id config =
  Room.current_room_id config

let dashboard_tasks_safe config =
  Room.get_tasks_raw_in_room config (dashboard_current_room_id config)

let dashboard_agents_safe config =
  Room.get_agents_raw_in_room config (dashboard_current_room_id config)

let dashboard_messages_safe config ~since_seq ~limit =
  Room.get_messages_raw_in_room config ~room_id:(dashboard_current_room_id config) ~since_seq ~limit

let dashboard_shell_http_json (config : Room.config) : Yojson.Safe.t =
  let agents = dashboard_agents_safe config in
  let tasks = dashboard_tasks_safe config in
  let keepers_json = keepers_dashboard_json ~compact:true config in
  let keepers_total = json_int_field "total" keepers_json ~default:0 in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("status", dashboard_shell_status_json config);
      ( "counts",
        `Assoc
          [
            ("agents", `Int (List.length agents));
            ("tasks", `Int (List.length tasks));
            ("keepers", `Int keepers_total);
          ] );
    ]

let dashboard_execution_http_json ~state ~sw ~clock request =
  let fixture = query_param request "fixture" in
  Dashboard_execution.json ?actor:(operator_actor_hint request) ?fixture
    ~config:state.Mcp_server.room_config ~sw ~clock
    ~proc_mgr:state.Mcp_server.proc_mgr ()

let dashboard_memory_http_json request : Yojson.Safe.t =
  let hearth = query_param request "hearth" in
  let sort_by = board_sort_order_of_request request in
  let exclude_system = bool_query_param request "exclude_system" ~default:false in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
  let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
  let posts = filter_board_posts ~exclude_system posts in
  let karma_map = Board_dispatch.get_all_karma () in
  let get_karma author =
    try List.assoc author karma_map with Not_found -> 0
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
          ] );
      ("posts", `List posts_json);
      ("count", `Int (List.length posts_json));
      ("limit", `Int limit);
      ("offset", `Int offset);
      ("sort_by", `String (board_sort_label sort_by));
    ]

let dashboard_governance_http_json request ~base_path : Yojson.Safe.t =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let status_filter =
    match query_param request "status" with
    | None -> None
    | Some raw -> (
        match String.lowercase_ascii (String.trim raw) with
        | "open" -> Some Council.Debate.Open
        | "closed" -> Some Council.Debate.Closed
        | "pending" -> Some Council.Debate.Pending
        | _ -> None)
  in
  Masc_mcp.Dashboard_governance.dashboard_json ~base_path ~limit ~offset
    ~status_filter

let dashboard_planning_http_json request ~(config : Room.config) : Yojson.Safe.t =
  let goals = Masc_mcp.Goal_store.list_goals config () in
  let rollup = Masc_mcp.Goal_store.compute_rollup goals in
  let mdal_json =
    match mdal_loops_json ~config request with
    | Ok json -> json
    | Error message -> `Assoc [ ("error", `String message); ("loops", `List []) ]
  in
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
      ("goals", `List (List.map Masc_mcp.Goal_store.goal_to_yojson goals));
      ("rollup", Masc_mcp.Goal_store.rollup_to_yojson rollup);
      ("mdal", mdal_json);
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

let operator_action_http_json ~state ~sw ~clock request ~args =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
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
      mcp_session_id = None;
    }
  in
  Operator_control.confirm_json ?actor_hint:(operator_actor_hint request) ctx args

let operator_error_json message =
  `Assoc [ ("status", `String "error"); ("message", `String message) ]

(** Shared runtime access for MCP handlers.
    main_eio delegates to the shared Eio_context instead of storing another
    copy of switch/clock/net state. *)
let get_switch () = Masc_mcp.Eio_context.get_switch ()
let get_clock () = Masc_mcp.Eio_context.get_clock ()
let get_net () = Masc_mcp.Eio_context.get_net ()

let command_plane_http_deps : Server_command_plane_http.deps =
  {
    query_param;
    int_query_param;
    operator_actor_hint;
    get_session_id_any;
    auth_token_from_request;
    get_switch;
    get_clock;
    get_net;
    get_origin;
    cors_headers;
  }

let command_plane_summary_http_json ~state =
  Server_command_plane_http.command_plane_summary_http_json ~state

let command_plane_snapshot_http_json ~state =
  Server_command_plane_http.command_plane_snapshot_http_json ~state

let command_plane_topology_http_json ~state =
  Server_command_plane_http.command_plane_topology_http_json ~state

let command_plane_units_http_json ~state =
  Server_command_plane_http.command_plane_units_http_json ~state

let command_plane_operations_http_json ~state request =
  Server_command_plane_http.command_plane_operations_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_detachments_http_json ~state request =
  Server_command_plane_http.command_plane_detachments_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_detachment_status_http_json ~state request =
  Server_command_plane_http.command_plane_detachment_status_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_decisions_http_json ~state request =
  Server_command_plane_http.command_plane_decisions_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_capacity_http_json ~state =
  Server_command_plane_http.command_plane_capacity_http_json ~state

let command_plane_alerts_http_json ~state =
  Server_command_plane_http.command_plane_alerts_http_json ~state

let command_plane_traces_http_json ~state request =
  Server_command_plane_http.command_plane_traces_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_swarm_http_json ~state request =
  Server_command_plane_http.command_plane_swarm_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_unit_define_http_json ~state request ~args =
  Server_command_plane_http.command_plane_unit_define_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_operation_start_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_start_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_chain_summary_http_json ~state request =
  Server_command_plane_http.command_plane_chain_summary_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_chain_run_http_json ~state request run_id =
  Server_command_plane_http.command_plane_chain_run_http_json
    ~deps:command_plane_http_deps ~state request run_id

let chain_http_error_status message =
  Server_command_plane_http.chain_http_error_status message

let command_plane_chain_events_http ~request reqd =
  Server_command_plane_http.command_plane_chain_events_http
    ~deps:command_plane_http_deps ~request reqd

let command_plane_chain_events_h2 ~request h2_reqd =
  Server_command_plane_http.command_plane_chain_events_h2
    ~deps:command_plane_http_deps ~request h2_reqd

let command_plane_operation_checkpoint_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_checkpoint_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_unit_reparent_http_json ~state request ~args =
  Server_command_plane_http.command_plane_unit_reparent_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_unit_reassign_http_json ~state request ~args =
  Server_command_plane_http.command_plane_unit_reassign_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_operation_pause_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_pause_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_operation_resume_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_resume_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_operation_stop_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_stop_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_operation_finalize_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_finalize_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_dispatch_plan_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_plan_http_json ~state request
    ~args

let command_plane_dispatch_assign_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_assign_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_dispatch_rebalance_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_rebalance_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_dispatch_escalate_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_escalate_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_dispatch_recall_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_recall_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_dispatch_tick_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_tick_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_policy_status_http_json ~state =
  Server_command_plane_http.command_plane_policy_status_http_json ~state

let command_plane_policy_approve_http_json ~state request ~args =
  Server_command_plane_http.command_plane_policy_approve_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_policy_deny_http_json ~state request ~args =
  Server_command_plane_http.command_plane_policy_deny_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_policy_update_http_json ~state request ~args =
  Server_command_plane_http.command_plane_policy_update_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_policy_freeze_http_json ~state request ~args =
  Server_command_plane_http.command_plane_policy_freeze_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_policy_kill_switch_http_json ~state request ~args =
  Server_command_plane_http.command_plane_policy_kill_switch_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_help_http_json () =
  Server_command_plane_http.command_plane_help_http_json ()

let command_plane_error_json message =
  Server_command_plane_http.command_plane_error_json message
let parse_host_port host_header default_host default_port =
  match host_header with
  | None -> (default_host, default_port)
  | Some host_value ->
      (match String.split_on_char ':' host_value with
       | [host] -> (host, default_port)
       | host :: port_str :: _ ->
           let port = try int_of_string port_str with Failure _ -> default_port in
           (host, port)
       | _ -> (default_host, default_port))

(** Utility: string prefix check *)
let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

(** Allowed origins for DNS rebinding protection *)
let allowed_origins = [
  "http://localhost";
  "https://localhost";
  "http://127.0.0.1";
  "https://127.0.0.1";
  (* Cloudflare tunnel *)
  "https://masc.crying.pictures";
]

(** Validate Origin header for DNS rebinding protection *)
let validate_origin (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "origin" with
  | None -> true
  | Some origin ->
      List.exists (fun prefix -> starts_with ~prefix origin) allowed_origins

(** Check if client accepts SSE *)
let accepts_sse (request : Httpun.Request.t) =
  Http_negotiation.accepts_sse_header
    (Httpun.Headers.get request.headers "accept")

(** Check if client accepts MCP Streamable HTTP (JSON + SSE) *)
let accepts_streamable_mcp (request : Httpun.Request.t) =
  Http_negotiation.accepts_streamable_mcp
    (Httpun.Headers.get request.headers "accept")

let request_force_json_response =
  Server_mcp_transport_http.request_force_json_response

let allow_legacy_accept = Server_mcp_transport_http.allow_legacy_accept

let classify_mcp_accept = Server_mcp_transport_http.classify_mcp_accept

let legacy_accept_warning_headers =
  Server_mcp_transport_http.legacy_accept_warning_headers

let legacy_transport_deprecation_headers =
  Server_mcp_transport_http.legacy_transport_deprecation_headers

let force_json_response = Server_mcp_transport_http.force_json_response

let get_last_event_id = Server_mcp_transport_http.get_last_event_id

let mcp_transport_json_headers session_id protocol_version origin =
  Server_mcp_transport_http.json_headers
    ~deps:
      {
        get_origin = get_origin;
        cors_headers = cors_headers;
        auth_token_from_request = auth_token_from_request;
        get_server_state_opt = (fun () -> !server_state);
        verify_mcp_auth =
          (fun ~base_path request ->
            Result.map (fun _ -> ()) (verify_mcp_auth ~base_path request));
        verify_operator_mcp_auth =
          (fun ~base_path request ->
            Result.map (fun _ -> ())
              (verify_operator_mcp_auth ~base_path request));
      }
    session_id protocol_version origin

let mcp_headers = Server_mcp_transport_http.mcp_headers

let json_headers = mcp_transport_json_headers

(** GraphQL response headers *)
let graphql_headers origin =
  [("content-type", "application/json")]
  @ cors_headers origin

(** GraphQL Playground HTML (GET /graphql) *)
let graphql_playground_html ~nonce =
  String.concat "" [
    {|
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="user-scalable=no,initial-scale=1,minimum-scale=1,maximum-scale=1" />
    <title>MASC GraphQL Playground</title>
    <link rel="stylesheet" href="/static/css/middleware.css" />
  </head>
  <body>
    <style>
      html { font-family: "Open Sans", sans-serif; overflow: hidden; }
      body { margin: 0; background: #172a3a; }
      .playgroundIn { animation: playgroundIn .5s ease-out forwards; }
      @keyframes playgroundIn {
        from { opacity: 0; transform: translateY(10px); }
        to { opacity: 1; transform: translateY(0); }
      }
    </style>
    <style>
      .fadeOut { animation: fadeOut .5s ease-out forwards; }
      @keyframes fadeIn {
        from { opacity: 0; transform: translateY(-10px); }
        to { opacity: 1; transform: translateY(0); }
      }
      @keyframes fadeOut {
        from { opacity: 1; transform: translateY(0); }
        to { opacity: 0; transform: translateY(-10px); }
      }
      @keyframes appearIn {
        from { opacity: 0; transform: translateY(0); }
        to { opacity: 1; transform: translateY(0); }
      }
      @keyframes scaleIn {
        from { transform: scale(0); }
        to { transform: scale(1); }
      }
      @keyframes innerDrawIn {
        0% { stroke-dashoffset: 70; }
        50% { stroke-dashoffset: 140; }
        100% { stroke-dashoffset: 210; }
      }
      @keyframes outerDrawIn {
        0% { stroke-dashoffset: 76; }
        100% { stroke-dashoffset: 152; }
      }
      #loading-wrapper {
        position: absolute;
        width: 100vw;
        height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        flex-direction: column;
      }
      .logo {
        width: 75px;
        height: 75px;
        margin-bottom: 20px;
        opacity: 0;
        animation: fadeIn .5s ease-out forwards;
      }
      .text {
        font-size: 32px;
        font-weight: 200;
        text-align: center;
        color: rgba(255, 255, 255, .6);
        opacity: 0;
        animation: fadeIn .5s ease-out forwards;
      }
      .text strong { font-weight: 400; }
    </style>
    <div id="loading-wrapper">
      <svg class="logo" viewBox="0 0 128 128" xmlns:xlink="http://www.w3.org/1999/xlink">
        <title>GraphQL Playground Logo</title>
        <defs>
          <linearGradient id="linearGradient-1" x1="4.86%" x2="96.21%" y1="0%" y2="99.66%">
            <stop stop-color="#E00082" stop-opacity=".8" offset="0%"></stop>
            <stop stop-color="#E00082" offset="100%"></stop>
          </linearGradient>
        </defs>
        <g>
          <rect id="Gradient" width="127.96" height="127.96" y="1" fill="url(#linearGradient-1)" rx="4"></rect>
          <path id="Border" fill="#E00082" fill-rule="nonzero" d="M4.7 2.84c-1.58 0-2.86 1.28-2.86 2.85v116.57c0 1.57 1.28 2.84 2.85 2.84h116.57c1.57 0 2.84-1.26 2.84-2.83V5.67c0-1.55-1.26-2.83-2.83-2.83H4.67zM4.7 0h116.58c3.14 0 5.68 2.55 5.68 5.7v116.58c0 3.14-2.54 5.68-5.68 5.68H4.68c-3.13 0-5.68-2.54-5.68-5.68V5.68C-1 2.56 1.55 0 4.7 0z"></path>
          <path class="bglIGM" x="64" y="28" fill="#fff" d="M64 36c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8"></path>
          <path class="ksxRII" x="95.98500061035156" y="46.510000228881836" fill="#fff" d="M89.04 50.52c-2.2-3.84-.9-8.73 2.94-10.96 3.83-2.2 8.72-.9 10.95 2.94 2.2 3.84.9 8.73-2.94 10.96-3.85 2.2-8.76.9-10.97-2.94"></path>
          <path class="cWrBmb" x="95.97162628173828" y="83.4900016784668" fill="#fff" d="M102.9 87.5c-2.2 3.84-7.1 5.15-10.94 2.94-3.84-2.2-5.14-7.12-2.94-10.96 2.2-3.84 7.12-5.15 10.95-2.94 3.86 2.23 5.16 7.12 2.94 10.96"></path>
          <path class="Wnusb" x="64" y="101.97999572753906" fill="#fff" d="M64 110c-4.43 0-8-3.6-8-8.02 0-4.44 3.57-8.02 8-8.02s8 3.58 8 8.02c0 4.4-3.57 8.02-8 8.02"></path>
          <path class="bfPqf" x="32.03982162475586" y="83.4900016784668" fill="#fff" d="M25.1 87.5c-2.2-3.84-.9-8.73 2.93-10.96 3.83-2.2 8.72-.9 10.95 2.94 2.2 3.84.9 8.73-2.94 10.96-3.85 2.2-8.74.9-10.95-2.94"></path>
          <path class="edRCTN" x="32.033552169799805" y="46.510000228881836" fill="#fff" d="M38.96 50.52c-2.2 3.84-7.12 5.15-10.95 2.94-3.82-2.2-5.12-7.12-2.92-10.96 2.2-3.84 7.12-5.15 10.95-2.94 3.83 2.23 5.14 7.12 2.94 10.96"></path>
          <path class="iEGVWn" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M63.55 27.5l32.9 19-32.9-19z"></path>
          <path class="bsocdx" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M96 46v38-38z"></path>
          <path class="jAZXmP" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M96.45 84.5l-32.9 19 32.9-19z"></path>
          <path class="hSeArx" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M64.45 103.5l-32.9-19 32.9 19z"></path>
          <path class="bVgqGk" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M32 84V46v38z"></path>
          <path class="hEFqBt" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M31.55 46.5l32.9-19-32.9 19z"></path>
          <path class="dzEKCM" id="Triangle-Bottom" stroke="#fff" stroke-width="4" d="M30 84h70" stroke-linecap="round"></path>
          <path class="DYnPx" id="Triangle-Left" stroke="#fff" stroke-width="4" d="M65 26L30 87" stroke-linecap="round"></path>
          <path class="hjPEAQ" id="Triangle-Right" stroke="#fff" stroke-width="4" d="M98 87L63 26" stroke-linecap="round"></path>
        </g>
      </svg>
      <div class="text">Loading <strong>GraphQL Playground</strong></div>
    </div>
    <div id="root"></div>
    <script nonce="|};
    nonce;
    {|">
      window.addEventListener("load", function () {
        var loading = document.getElementById("loading-wrapper");
        if (loading) {
          loading.classList.add("fadeOut");
        }
        var root = document.getElementById("root");
        if (!root) {
          return;
        }
        root.classList.add("playgroundIn");
        GraphQLPlayground.init(root, {
          endpoint: "/graphql",
          settings: { "request.credentials": "same-origin" }
        });
      });
    </script>
    <script src="/static/js/middleware.js"></script>
  </body>
</html>
|};
  ]

let graphql_csp_header nonce =
  Printf.sprintf
    "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; \
     connect-src 'self'; img-src 'self' data:; \
     script-src 'self' 'nonce-%s' 'unsafe-eval'; \
     style-src 'self' 'unsafe-inline'; \
     font-src 'self' data:; \
     worker-src 'self' blob:"
    nonce

(** Resolve assets root *)
let assets_root () =
  let is_dir path =
    Sys.file_exists path && Sys.is_directory path
  in
  let exe_assets =
    let exe_dir = Filename.dirname Sys.executable_name in
    let root = Filename.dirname (Filename.dirname (Filename.dirname exe_dir)) in
    Filename.concat root "assets"
  in
  let env_assets =
    match Sys.getenv_opt "MASC_ASSETS_ROOT" with
    | Some path when String.trim path <> "" -> Some path
    | _ -> Sys.getenv_opt "MASC_ASSETS_DIR"
  in
  match env_assets with
  | Some path when is_dir path -> path
  | _ when is_dir exe_assets -> exe_assets
  | _ when is_dir (Filename.concat (Sys.getcwd ()) "assets") ->
      Filename.concat (Sys.getcwd ()) "assets"
  | _ -> Filename.concat (Sys.getcwd ()) "assets"

(** Local GraphiQL assets *)
let graphiql_asset_root () =
  Filename.concat (assets_root ()) "graphiql"

let graphiql_asset_path name =
  Filename.concat (graphiql_asset_root ()) name

let asset_content_type name =
  if Filename.check_suffix name ".css" then
    "text/css; charset=utf-8"
  else if Filename.check_suffix name ".js" then
    "application/javascript; charset=utf-8"
  else if Filename.check_suffix name ".html" then
    "text/html; charset=utf-8"
  else if Filename.check_suffix name ".svg" then
    "image/svg+xml"
  else if Filename.check_suffix name ".png" then
    "image/png"
  else if Filename.check_suffix name ".jpg" || Filename.check_suffix name ".jpeg" then
    "image/jpeg"
  else if Filename.check_suffix name ".webp" then
    "image/webp"
  else if Filename.check_suffix name ".json" then
    "application/json"
  else if Filename.check_suffix name ".woff2" then
    "font/woff2"
  else if Filename.check_suffix name ".map" then
    "application/json"
  else
    "application/octet-stream"

let read_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with exn -> Error (Printexc.to_string exn)

let serve_graphiql_asset name _request reqd =
  let path = graphiql_asset_path name in
  match read_file path with
  | Ok body ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | Error _ ->
      Http.Response.not_found reqd

(** Local GraphQL Playground assets *)
let playground_asset_root () =
  Filename.concat (assets_root ()) "playground"

let playground_asset_path name =
  Filename.concat (playground_asset_root ()) name

let serve_playground_asset name _request reqd =
  let path = playground_asset_path name in
  match read_file path with
  | Ok body ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | Error _ ->
      Http.Response.not_found reqd

(** Dashboard SPA assets (Preact + HTM, built by Vite) *)
let dashboard_asset_root () =
  Filename.concat (assets_root ()) "dashboard"

let dashboard_index_path () =
  Filename.concat (dashboard_asset_root ()) "index.html"

let dashboard_etag () =
  try
    let st = Unix.stat (dashboard_index_path ()) in
    let hash =
      Digest.string (string_of_float st.Unix.st_mtime) |> Digest.to_hex
    in
    String.sub hash 0 12
  with _ -> "none"

let dashboard_index_cache_control = "no-store, max-age=0, must-revalidate"

let serve_dashboard_index request reqd =
  match read_file (dashboard_index_path ()) with
  | Ok body ->
      Http.Response.html_cached
        ~etag:(dashboard_etag ())
        ~request body reqd
  | Error _ ->
      Http.Response.html
        "<html><body>Dashboard build not found. Run: cd dashboard &amp;&amp; npm run build</body></html>"
        reqd

let serve_dashboard_static name _request reqd =
  let path = Filename.concat (dashboard_asset_root ()) name in
  match read_file path with
  | Ok body ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | Error _ ->
      Http.Response.not_found reqd

let favicon_svg = {|
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="12" fill="#0f172a"/>
  <circle cx="32" cy="32" r="18" fill="#1d4ed8"/>
  <path d="M22 42 L32 18 L42 42 Z" fill="#93c5fd"/>
</svg>
|}

let serve_favicon _request reqd =
  Http.Response.bytes ~content_type:"image/svg+xml" favicon_svg reqd

let is_dashboard_spa_deep_link path =
  starts_with ~prefix:"/dashboard/" path
  && not (starts_with ~prefix:"/dashboard/assets/" path)
  && path <> "/dashboard/credits"
  && path <> "/dashboard/lodge"

(** CORS preflight response headers *)
let cors_preflight_headers origin =
  [
    ("access-control-allow-origin", origin);
    ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
    ("access-control-allow-headers", cors_allow_headers_value);
    ("access-control-expose-headers", "Mcp-Session-Id, Mcp-Protocol-Version");
  ]

(** JSON-RPC error response helper *)
let json_rpc_error code message =
  Printf.sprintf
    {|{"jsonrpc":"2.0","error":{"code":%d,"message":"%s"},"id":null}|}
    code
    (String.escaped message)

let is_http_error_response = function
  | `Assoc fields ->
      let id_is_null =
        match List.assoc_opt "id" fields with
        | Some `Null -> true
        | _ -> false
      in
      let code =
        match List.assoc_opt "error" fields with
        | Some (`Assoc err_fields) ->
            (match List.assoc_opt "code" err_fields with
             | Some (`Int c) -> Some c
             | _ -> None)
        | _ -> None
      in
      id_is_null && (code = Some (-32700) || code = Some (-32600))
  | _ -> false

(** Server start time for uptime calculation *)
let server_start_time = Unix.gettimeofday ()

(** Health check handler *)
let health_handler _request reqd =
  let uptime_secs = int_of_float (Unix.gettimeofday () -. server_start_time) in
  let uptime_str =
    if uptime_secs < 60 then Printf.sprintf "%ds" uptime_secs
    else if uptime_secs < 3600 then Printf.sprintf "%dm %ds" (uptime_secs / 60) (uptime_secs mod 60)
    else Printf.sprintf "%dh %dm" (uptime_secs / 3600) ((uptime_secs mod 3600) / 60)
  in
  let build = Build_identity.current () in
  let lodge_json = Masc_mcp.Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let guardian_json = Masc_mcp.Guardian.status_json () in
  let sentinel_json = Masc_mcp.Sentinel.status_json () in
  let health_json = `Assoc [
    ("status", `String "ok");
    ("server", `String "masc-mcp");
    ("version", `String build.release_version);
    ("release_version", `String build.release_version);
    ("build", Build_identity.to_yojson build);
    ( "protocol",
      `Assoc
        [
          ("default", `String mcp_protocol_version_default);
          ( "supported",
            `List (List.map (fun v -> `String v) mcp_protocol_versions) );
        ] );
    ( "transport",
      `Assoc
        [
          ("streamable_http_default", `Bool true);
          ("allow_legacy_accept", `Bool allow_legacy_accept);
          ("legacy_endpoints_deprecated", `Bool true);
        ] );
    ("uptime", `String uptime_str);
    ("sse_clients", `Int (Masc_mcp.Sse.client_count ()));
    ("lodge", lodge_json);
    ("guardian", guardian_json);
    ("sentinel", sentinel_json);
  ] in
  Http.Response.json (Yojson.Safe.to_string health_json) reqd

let board_post_detail_json ~response_format ~post_id =
  match Board_dispatch.get_post ~post_id with
  | Error _ ->
      (`Not_found, {|{"error":"Post not found"}|})
  | Ok post ->
      let author = Board.Agent_id.to_string post.author in
      let author_karma = Board_dispatch.get_agent_karma ~agent_name:author in
      let comments =
        match Board_dispatch.get_comments ~post_id with
        | Ok cs -> cs
        | Error _ -> []
      in
      let post_json = board_post_dashboard_json ~author_karma post in
      let comments_json = `List (List.map Board.comment_to_yojson comments) in
      let json =
        if String.equal (String.lowercase_ascii (String.trim response_format)) "flat" then
          match post_json with
          | `Assoc fields -> `Assoc (fields @ [ ("comments", comments_json) ])
          | _ -> `Assoc [ ("post", post_json); ("comments", comments_json) ]
        else
          `Assoc [ ("post", post_json); ("comments", comments_json) ]
      in
      (`OK, Yojson.Safe.to_string json)

let debate_status_filter_of_request request =
  match query_param request "status" with
  | None -> None
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "open" -> Some Council.Debate.Open
      | "closed" -> Some Council.Debate.Closed
      | "pending" -> Some Council.Debate.Pending
      | _ -> None)

let council_debates_json request ~base_path =
  let config = Council.make_config ~base_path in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let fetch_limit = limit + offset in
  let status_filter = debate_status_filter_of_request request in
  let debates = Council.DebateApi.list_all ~config ~status_filter ~limit:fetch_limit () in
  let paged = debates |> drop offset |> take limit in
  let items =
    List.map
      (fun (d : Council.Debate.debate) ->
        `Assoc
          [
            ("id", `String d.id);
            ("topic", `String d.topic);
            ("status", `String (Council.Debate.status_to_string d.status));
            ("argument_count", `Int (List.length d.arguments));
            ("created_at", `Float d.created_at);
            ("created_at_iso", `String (iso8601_of_unix d.created_at));
          ])
      paged
  in
  `Assoc
    [
      ("debates", `List items);
      ("count", `Int (List.length items));
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let council_sessions_json request =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let sessions = Council.ConsensusApi.list_active () |> drop offset |> take limit in
  let items =
    List.map
      (fun (s : Council.Consensus.session) ->
        `Assoc
          [
            ("id", `String s.id);
            ("topic", `String s.topic);
            ("initiator", `String s.initiator);
            ("votes", `Int (List.length s.votes));
            ("quorum", `Int s.quorum);
            ("threshold", `Float s.threshold);
            ("state", Council.Consensus.voting_state_to_yojson s.state);
            ("created_at", `Float s.created_at);
            ("created_at_iso", `String (iso8601_of_unix s.created_at));
          ])
      sessions
  in
  `Assoc
    [
      ("sessions", `List items);
      ("count", `Int (List.length items));
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let council_debate_summary_json ~base_path ~debate_id =
  let (status, json) =
    Masc_mcp.Dashboard_governance.debate_detail_json ~base_path ~debate_id
  in
  let http_status =
    match status with
    | `OK -> `OK
    | `Not_found -> `Not_found
  in
  (http_status, json)

let council_session_summary_json ~base_path ~session_id =
  let (status, json) =
    Masc_mcp.Dashboard_governance.consensus_detail_json ~base_path ~session_id
  in
  let http_status =
    match status with
    | `OK -> `OK
    | `Not_found -> `Not_found
  in
  (http_status, json)

(** CORS preflight handler *)
let options_handler request reqd =
  let origin = get_origin request in
  let headers = Httpun.Headers.of_list (
    ("content-length", "0") :: cors_preflight_headers origin
  ) in
  let response = Httpun.Response.create ~headers `No_content in
  Httpun.Reqd.respond_with_string reqd response ""

(** Helper functions to get initialized state or fail *)
let get_server_state () = match !server_state with
  | Some s -> s
  | None -> failwith "Server state not initialized"


let http_status_of_graphql = function
  | `OK -> `OK
  | `Bad_request -> `Bad_request

let handle_get_graphql _request reqd =
  let nonce =
    let rng = Random.State.make_self_init () in
    let bytes = Bytes.init 16 (fun _ -> Char.chr (Random.State.int rng 256)) in
    Base64.encode_string (Bytes.to_string bytes)
  in
  let headers = [
    ("content-security-policy", graphql_csp_header nonce);
  ] in
  let body = graphql_playground_html ~nonce in
  Http.Response.html ~headers body reqd

let handle_post_graphql request reqd =
  let origin = get_origin request in
  Http.Request.read_body_async reqd (fun body_str ->
    let state = get_server_state ()
    in
    let response = Graphql_api.handle_request ~config:state.room_config body_str in
    let status = http_status_of_graphql response.status in
    let headers = Httpun.Headers.of_list (
      ("content-length", string_of_int (String.length response.body))
      :: graphql_headers origin
    ) in
    let http_response = Httpun.Response.create ~headers status in
    Httpun.Reqd.respond_with_string reqd http_response response.body
  )

let handle_graphql request reqd =
  match Http.Request.method_ request with
  | `GET -> handle_get_graphql request reqd
  | `POST -> handle_post_graphql request reqd
  | _ -> Http.Response.method_not_allowed reqd

let mcp_transport_http_deps : Server_mcp_transport_http.deps =
  {
    get_origin;
    cors_headers;
    auth_token_from_request;
    get_server_state_opt = (fun () -> !server_state);
    verify_mcp_auth =
      (fun ~base_path request ->
        Result.map (fun _ -> ()) (verify_mcp_auth ~base_path request));
    verify_operator_mcp_auth =
      (fun ~base_path request ->
        Result.map (fun _ -> ()) (verify_operator_mcp_auth ~base_path request));
  }

let check_sse_connect_guard = Server_mcp_transport_http.check_sse_connect_guard

let stop_sse_session = Server_mcp_transport_http.stop_sse_session

let close_all_sse_connections =
  Server_mcp_transport_http.close_all_sse_connections

let handle_get_mcp ?legacy_messages_endpoint ?(profile = Mcp_eio.Full) request reqd =
  Server_mcp_transport_http.handle_get_mcp ~deps:mcp_transport_http_deps
    ?legacy_messages_endpoint ~profile request reqd

let sse_simple_handler request reqd =
  Server_mcp_transport_http.sse_simple_handler ~deps:mcp_transport_http_deps
    request reqd

(** TRPG SSE poll interval in seconds *)
let trpg_sse_poll_interval_s = 2.0

(** TRPG SSE keepalive interval in seconds *)
let trpg_sse_keepalive_s = 30.0

(** Format a single TRPG event as an SSE frame.
    Uses the event's seq as the SSE id, and the event_type string as the SSE event field. *)
let trpg_event_to_sse (ev : Masc_mcp.Trpg_engine_event.t) : string =
  let data = Yojson.Safe.to_string (Masc_mcp.Trpg_engine_event.to_yojson ev) in
  let event_type_str = Masc_mcp.Trpg_engine_event.string_of_event_type ev.event_type in
  Printf.sprintf "id: %d\nevent: %s\ndata: %s\n\n" ev.seq event_type_str data

(** Handle TRPG SSE streaming endpoint (HTTP/1.1).
    Opens a long-lived text/event-stream connection, replays events after Last-Event-ID,
    then polls SQLite every 2s for new events. Sends keepalive comments every 30s. *)
let handle_trpg_sse ~base_dir ~room_id ~event_type_filter request reqd =
  let room_id = String.trim room_id in
  if room_id = "" then begin
    let origin = get_origin request in
    Http.Response.json ~status:`Bad_request
      ~extra_headers:(cors_headers origin)
      (Yojson.Safe.to_string (trpg_error_json "room_id is required")) reqd
  end else
    let origin = get_origin request in
    match trpg_parse_event_type_filter event_type_filter with
    | Error (`Bad_request, msg) ->
        Http.Response.json ~status:`Bad_request
          ~extra_headers:(cors_headers origin)
          (Yojson.Safe.to_string (trpg_error_json msg)) reqd
    | Ok event_type_opt ->
        let last_event_id =
          match Httpun.Headers.get request.Httpun.Request.headers "last-event-id" with
          | Some id -> (try int_of_string id with Failure _ -> 0)
          | None -> 0
        in
        let headers = Httpun.Headers.of_list ([
          ("content-type", "text/event-stream");
          ("cache-control", "no-cache");
          ("connection", "keep-alive");
        ] @ cors_headers origin) in
        let response = Httpun.Response.create ~headers `OK in
        let writer = Httpun.Reqd.respond_with_streaming reqd response in
        let mutex = Eio.Mutex.create () in
        let closed = ref false in
        let last_seq = ref last_event_id in

        let send_raw_data data =
          if !closed || Httpun.Body.Writer.is_closed writer then begin
            closed := true; false
          end else
            try
              Eio.Mutex.use_rw ~protect:true mutex (fun () ->
                Httpun.Body.Writer.write_string writer data;
                Httpun.Body.Writer.flush writer (fun _ -> ()));
              true
            with _exn ->
              closed := true; false
        in

        (* Send initial comment to confirm connection *)
        ignore (send_raw_data
          (Printf.sprintf ": TRPG SSE stream for room %s (after_seq=%d)\nretry: 3000\n\n"
             room_id !last_seq));

        (* Replay existing events newer than last_seq *)
        (match
           (if !last_seq > 0 then
              Masc_mcp.Trpg_engine_store_sqlite.read_events_after
                ~base_dir ~room_id ~after_seq:!last_seq
            else
              Masc_mcp.Trpg_engine_store_sqlite.read_events ~base_dir ~room_id)
         with
         | Ok events ->
             let events = match event_type_opt with
               | None -> events
               | Some et ->
                   List.filter
                     (fun (ev : Masc_mcp.Trpg_engine_event.t) -> ev.event_type = et)
                     events
             in
             List.iter (fun ev ->
               if not !closed then begin
                 ignore (send_raw_data (trpg_event_to_sse ev));
                 last_seq := max !last_seq ev.Masc_mcp.Trpg_engine_event.seq
               end) events
         | Error _ -> ());

        (* Start polling fiber for new events + keepalive *)
        (match Masc_mcp.Eio_context.get_switch_opt (), Masc_mcp.Eio_context.get_clock_opt () with
         | Some sw, Some clock ->
             Eio.Fiber.fork ~sw (fun () ->
               let is_cancelled = function
                 | Eio.Cancel.Cancelled _ -> true | _ -> false
               in
               let keepalive_counter = ref 0 in
               let polls_per_keepalive =
                 max 1 (int_of_float (trpg_sse_keepalive_s /. trpg_sse_poll_interval_s))
               in
               let rec loop () =
                 if not !closed then begin
                   (try Eio.Time.sleep clock trpg_sse_poll_interval_s
                    with exn -> if is_cancelled exn then raise exn);
                   if not !closed then begin
                     (match
                        Masc_mcp.Trpg_engine_store_sqlite.read_events_after
                          ~base_dir ~room_id ~after_seq:!last_seq
                      with
                      | Ok events ->
                          let events = match event_type_opt with
                            | None -> events
                            | Some et ->
                                List.filter
                                  (fun (ev : Masc_mcp.Trpg_engine_event.t) ->
                                    ev.event_type = et)
                                  events
                          in
                          List.iter (fun ev ->
                            if not !closed then begin
                              if not (send_raw_data (trpg_event_to_sse ev)) then
                                closed := true
                              else
                                last_seq := max !last_seq
                                  ev.Masc_mcp.Trpg_engine_event.seq
                            end) events
                      | Error _ -> ());
                     incr keepalive_counter;
                     if !keepalive_counter >= polls_per_keepalive then begin
                       keepalive_counter := 0;
                       if not !closed then
                         ignore (send_raw_data ": keepalive\n\n")
                     end
                   end;
                   loop ()
                 end
               in
               try loop () with exn ->
                 if not (is_cancelled exn) then
                   Printf.eprintf "[TRPG-SSE] poll loop error for room %s: %s\n%!"
                     room_id (Printexc.to_string exn))
         | _ ->
             ignore (send_raw_data
               "event: error\ndata: {\"error\":\"server not ready\"}\n\n"))

let handle_get_operator_mcp request reqd =
  Server_mcp_transport_http.handle_get_operator_mcp
    ~deps:mcp_transport_http_deps request reqd

let handle_post_messages request reqd =
  Server_mcp_transport_http.handle_post_messages ~deps:mcp_transport_http_deps
    request reqd

let handle_post_mcp ?(profile = Mcp_eio.Full) request reqd =
  Server_mcp_transport_http.handle_post_mcp ~deps:mcp_transport_http_deps
    ~profile request reqd

let handle_delete_mcp ?(profile = Mcp_eio.Full) request reqd =
  Server_mcp_transport_http.handle_delete_mcp ~deps:mcp_transport_http_deps
    ~profile request reqd

let handle_ag_ui_events request reqd =
  Server_mcp_transport_http.handle_ag_ui_events ~deps:mcp_transport_http_deps
    request reqd

(** Build routes for MCP server *)
let make_routes ~port ~host ~sw ~clock =
  Http.Router.empty
  |> Http.Router.get "/health" health_handler
  |> Http.Router.get "/metrics" (fun request reqd ->
       with_read_auth (fun _state _req reqd ->
         let body = Masc_mcp.Prometheus.to_prometheus_text () in
         Http.Response.bytes ~content_type:"text/plain; version=0.0.4; charset=utf-8" body reqd
       ) request reqd)
  |> Http.Router.get "/.well-known/agent-card.json" (fun request reqd ->
       with_read_auth (fun _state req reqd ->
         let host_header = Httpun.Headers.get req.Httpun.Request.headers "host" in
         let (resolved_host, resolved_port) = parse_host_port host_header host port in
         let card = Masc_mcp.Agent_card.generate_default ~host:resolved_host ~port:resolved_port () in
         let json = Masc_mcp.Agent_card.to_json card |> Yojson.Safe.to_string in
         let a2a_version = Masc_mcp.A2a_tools.default_a2a_version in
         Http.Response.json ~extra_headers:[("A2A-Version", a2a_version)] json reqd
       ) request reqd)
  |> Http.Router.get "/ag-ui/events" handle_ag_ui_events
  (* Dashboard sub-routes: credits and lodge must come before the SPA catchall *)
  |> Http.Router.get "/dashboard/credits" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Response.html (Masc_mcp.Credits_dashboard.html ()) reqd
       ) request reqd)
  |> Http.Router.get "/dashboard/lodge" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         Http.Response.html_cached
           ~etag:(Masc_mcp.Lodge_dashboard.etag ())
           ~request:req
           (Masc_mcp.Lodge_dashboard.html ()) reqd
       ) request reqd)
  |> Http.Router.get "/favicon.ico" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_favicon req reqd
       ) request reqd)
  |> Http.Router.get "/favicon.svg" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_favicon req reqd
       ) request reqd)
  (* Dashboard SPA: static assets — prefix match for /dashboard/assets/* *)
  |> Http.Router.prefix_get "/dashboard/assets/"
       (fun request reqd ->
         let req_path = Http.Request.path request in
         let prefix_len = String.length "/dashboard/assets/" in
         let filename = String.sub req_path prefix_len (String.length req_path - prefix_len) in
         if Masc_mcp.Web_dashboard.is_safe_asset_relative_path filename then
           serve_dashboard_static ("assets/" ^ filename) request reqd
         else
           Http.Response.not_found reqd)
  (* Dashboard SPA: index.html *)
  |> Http.Router.get "/dashboard" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_dashboard_index req reqd
       ) request reqd)
  |> Http.Router.get "/dashboard/" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_dashboard_index req reqd
       ) request reqd)
  |> Http.Router.prefix_get "/dashboard/"
       (fun request reqd ->
         with_public_read (fun _state req reqd ->
           let req_path = Http.Request.path req in
           if is_dashboard_spa_deep_link req_path then
             serve_dashboard_index req reqd
           else
             Http.Response.not_found reqd
         ) request reqd)
  |> Http.Router.get "/api/v1/credits" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Response.json (Masc_mcp.Credits_dashboard.json_api ()) reqd
       ) request reqd)
  |> Http.Router.get "/" (fun _req reqd -> Http.Response.text "MASC MCP Server" reqd)
  |> Http.Router.get "/static/css/middleware.css"
       (serve_playground_asset "static/css/middleware.css")
  |> Http.Router.get "/static/js/middleware.js"
       (serve_playground_asset "static/js/middleware.js")
  |> Http.Router.get "/graphiql/graphiql.min.css"
       (serve_graphiql_asset "graphiql.min.css")
  |> Http.Router.get "/graphiql/graphiql.min.js"
       (serve_graphiql_asset "graphiql.min.js")
  |> Http.Router.get "/graphiql/react.production.min.js"
       (serve_graphiql_asset "react.production.min.js")
  |> Http.Router.get "/graphiql/react-dom.production.min.js"
       (serve_graphiql_asset "react-dom.production.min.js")
  |> Http.Router.get "/mcp" (fun request reqd ->
       with_read_auth (fun _state req reqd -> handle_get_mcp req reqd) request reqd)
  |> Http.Router.get "/mcp/operator" handle_get_operator_mcp
  |> Http.Router.post "/" handle_post_mcp
  |> Http.Router.post "/mcp" handle_post_mcp
  |> Http.Router.post "/mcp/operator" (handle_post_mcp ~profile:Mcp_eio.Operator_remote)
  |> Http.Router.add ~path:"/graphql" ~methods:[`GET; `POST]
       ~handler:(fun request reqd ->
         with_read_auth (fun _state req reqd -> handle_graphql req reqd) request reqd)
  |> Http.Router.post "/messages" handle_post_messages
  |> Http.Router.get "/sse"
       (fun request reqd ->
         with_public_read (fun _state req reqd ->
           handle_get_mcp
             ~legacy_messages_endpoint:(legacy_messages_endpoint_url req)
             req reqd
         ) request reqd)
  |> Http.Router.get "/sse/simple" (fun request reqd ->
       with_public_read (fun _state req reqd -> sse_simple_handler req reqd) request reqd)
  (* REST API for dashboard - direct Room access *)
  |> Http.Router.get "/api/v1/status" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         let room_state = Masc_mcp.Room.read_state config in
         let tempo = Masc_mcp.Tempo.get_tempo config in
         let json = `Assoc [
           ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
           ("project", `String room_state.project);
           ("tempo_interval_s", `Float tempo.current_interval_s);
           ("paused", `Bool room_state.paused);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/tasks" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let status_filter = query_param req "status" in
         let include_done = bool_query_param req "include_done" ~default:false in
         let include_cancelled = bool_query_param req "include_cancelled" ~default:false in
         let limit = int_query_param req "limit" ~default:50 in
         let offset = int_query_param req "offset" ~default:0 in
         let tasks = Masc_mcp.Room.get_tasks_raw config in
         let filtered =
           match status_filter with
           | None -> tasks
           | Some status ->
               List.filter (fun (t : Masc_mcp.Types.task) ->
                 String.equal status (Masc_mcp.Types.string_of_task_status t.task_status)
               ) tasks
         in
         let filtered =
           match status_filter with
           | Some _ -> filtered
           | None ->
               List.filter (fun (t : Masc_mcp.Types.task) ->
                 let is_done = match t.task_status with
                   | Types.Done _ -> true
                   | _ -> false
                 in
                 let is_cancelled = match t.task_status with
                   | Types.Cancelled _ -> true
                   | _ -> false
                 in
                 (include_done || not is_done) &&
                 (include_cancelled || not is_cancelled)
               ) filtered
         in
         let total = List.length filtered in
         let page =
           filtered
           |> List.filteri (fun idx _ -> idx >= offset && idx < offset + limit)
         in
         let tasks_json = List.map (fun (t : Masc_mcp.Types.task) ->
           `Assoc [
             ("id", `String t.id);
             ("title", `String t.title);
             ("status", `String (Masc_mcp.Types.string_of_task_status t.task_status));
             ("priority", `Int t.priority);
             ("assignee", match t.task_status with
               | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } -> `String assignee
               | _ -> `Null);
           ]
         ) page in
         let json = `Assoc [
           ("tasks", `List tasks_json);
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/agents" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let status_filter = query_param req "status" in
         let limit = int_query_param req "limit" ~default:50 in
         let offset = int_query_param req "offset" ~default:0 in
         let agents = Masc_mcp.Room.get_agents_raw config in
         let filtered =
           match status_filter with
           | None -> agents
           | Some status ->
               List.filter (fun (a : Masc_mcp.Types.agent) ->
                 String.equal status (Masc_mcp.Types.string_of_agent_status a.status)
               ) agents
         in
         let total = List.length filtered in
         let page =
           filtered
           |> List.filteri (fun idx _ -> idx >= offset && idx < offset + limit)
         in
         let agents_json = List.map (fun (a : Masc_mcp.Types.agent) ->
           `Assoc [
             ("name", `String a.name);
             ("status", `String (Masc_mcp.Types.string_of_agent_status a.status));
             ("current_task", match a.current_task with Some t -> `String t | None -> `Null);
           ]
         ) page in
         let json = `Assoc [
           ("agents", `List agents_json);
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/messages" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let since_seq = int_query_param req "since_seq" ~default:0 in
         let limit = int_query_param req "limit" ~default:20 in
         let agent_filter = query_param req "agent" in
         let msgs = Masc_mcp.Room.get_messages_raw config ~since_seq ~limit:500 in
         let filtered =
           match agent_filter with
           | None -> msgs
           | Some agent ->
               List.filter (fun (m : Masc_mcp.Types.message) ->
                 String.equal agent m.from_agent
               ) msgs
         in
         let total = List.length filtered in
         let page = filtered |> List.filteri (fun idx _ -> idx < limit) in
         let msgs_json = List.map (fun (m : Masc_mcp.Types.message) ->
           `Assoc [
             ("from", `String m.from_agent);
             ("content", `String m.content);
             ("timestamp", `String m.timestamp);
             ("seq", `Int m.seq);
           ]
         ) page in
         let json = `Assoc [
           ("messages", `List msgs_json);
           ("limit", `Int limit);
           ("since_seq", `Int since_seq);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/events" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         match trpg_read_events_json ~base_dir ~room_id ~after_seq ~event_type_filter with
         | Ok json ->
             let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
             respond_json_with_cors request reqd (Yojson.Safe.to_string normalized)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/events" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_append_event_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/room/current" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         let room_id = Option.value ~default:"default" (Masc_mcp.Room.read_current_room config) in
         let json = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
         respond_json_with_cors request reqd (Yojson.Safe.to_string json)
       ) request reqd)
  |> Http.Router.post "/api/v1/room/current" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
              (match trpg_parse_required_string "room_id" json with
               | Error (`Bad_request, msg) ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg))
               | Ok room_id ->
                   let room_id = String.trim room_id in
                   if room_id = "" then
                     respond_json_with_cors ~status:`Bad_request request reqd
                       (Yojson.Safe.to_string
                          (trpg_error_json "room_id cannot be empty"))
                   else (
                     Masc_mcp.Room.write_current_room config room_id;
                     Masc_mcp.Room.ensure_room_entry config room_id;
                     let response = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
                     respond_json_with_cors request reqd (Yojson.Safe.to_string response)))
           with
           | Yojson.Json_error msg ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string
                    (trpg_error_json (Printf.sprintf "invalid json: %s" msg))))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/state" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_derive_state_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/lobby/catalog" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match
           trpg_lobby_catalog_json ~base_dir ~config:state.Mcp_server.room_config ~room_id
             ~rule_module
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/lobby/preflight" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         let dm_keeper = query_param req "dm" in
         let player_keepers =
           query_param req "players" |> Option.value ~default:"" |> split_csv_nonempty
         in
         let models =
           query_param req "models" |> Option.value ~default:"" |> split_csv_nonempty
         in
         match
           trpg_lobby_preflight_json ~base_dir ~config:state.Mcp_server.room_config ~room_id
             ~rule_module ~dm_keeper ~player_keepers ~models
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/overview" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_overview_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/control/state" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_control_state_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/models" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         respond_json_with_cors request reqd
           (Yojson.Safe.to_string (trpg_available_models_json ()))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/dice/roll" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_dice_roll_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/turns/advance" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_turn_advance_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors request reqd (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/rounds/run" (fun request reqd ->
       with_public_read (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           let agent_name =
             Option.value ~default:"dashboard" (agent_from_request req)
           in
           match Masc_mcp.Eio_context.get_switch_opt (), Masc_mcp.Eio_context.get_clock_opt () with
           | Some sw, Some clock -> (
               match
                 trpg_round_run_json
                   ~state
                   ~agent_name
                   ~sw
                   ~clock
                   ~idempotency_key:
                     (get_header_any_case req.Httpun.Request.headers "idempotency-key")
                   ~body_str
               with
               | Ok json ->
                   respond_json_with_cors request reqd (Yojson.Safe.to_string json)
               | Error (`Bad_request, msg) ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg))
               | Error (`Internal_server_error, msg) ->
                   respond_json_with_cors ~status:`Internal_server_error request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg)))
           | _ ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string
                    (trpg_error_json "trpg runtime not initialized"))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/stream" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
         | Ok json ->
             let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
             respond_json_with_cors request reqd (Yojson.Safe.to_string normalized)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/timeline" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         let actor_filter = query_param req "actor" in
         let phase_filter = query_param req "phase" in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         match
           trpg_timeline_json ~base_dir ~room_id ~after_seq ~event_type_filter
             ~actor_filter ~phase_filter ~limit
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/stream/sse" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let event_type_filter = query_param req "event_type" in
         handle_trpg_sse ~base_dir ~room_id ~event_type_filter request reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/spawn" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match
             trpg_actor_spawn_json ~base_dir
               ~idempotency_key:
                 (get_header_any_case req.Httpun.Request.headers "idempotency-key")
               ~body_str
           with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/claim" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_actor_claim_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/release" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_actor_release_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/tts" (fun request reqd ->
       Http.Request.read_body_async reqd (fun body_str ->
         match trpg_tts_proxy ~body_str with
         | Ok audio_bytes ->
             let origin = get_origin request in
             Http.Response.bytes ~content_type:"audio/mpeg"
               ~headers:(cors_headers origin) audio_bytes reqd
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (_, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))))
  |> Http.Router.post "/api/v1/broadcast" (fun request reqd ->
       (* POST /api/v1/broadcast - HTTP API for external tools like autocov *)
       with_read_auth (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let agent_name = json |> Yojson.Safe.Util.member "agent_name" |> Yojson.Safe.Util.to_string in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Masc_mcp.Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with e ->
             Http.Response.json
               (Printf.sprintf {|{"ok":false,"error":"%s"}|} (Printexc.to_string e))
               reqd
         )
       ) request reqd)
  |> Http.Router.post "/broadcast" (fun request reqd ->
       (* POST /broadcast - Alias for autocov compatibility *)
       with_read_auth (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let agent_name = json |> Yojson.Safe.Util.member "agent_name" |> Yojson.Safe.Util.to_string in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Masc_mcp.Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with e ->
             Http.Response.json
               (Printf.sprintf {|{"ok":false,"error":"%s"}|} (Printexc.to_string e))
               reqd
         )
       ) request reqd)

  (* Batch dashboard endpoint: single request replaces 4 separate API calls *)
  |> Http.Router.get "/api/v1/dashboard" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json =
           `Assoc
             [
               ("error", `String "dashboard batch contract removed");
               ("message", `String "Use /api/v1/dashboard/shell and surface-specific projection endpoints.");
             ]
         in
         Http.Response.json ~status:`Gone ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/shell" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_shell_http_json state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/execution" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_execution_http_json ~state ~sw ~clock request in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/memory" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = dashboard_memory_http_json req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/governance" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json = dashboard_governance_http_json req ~base_path in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/planning" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_planning_http_json req ~config:state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/semantics" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = dashboard_semantics_http_json () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/mission" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_mission_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/mission/briefing" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_mission_briefing_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/proof" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_proof_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/mdal/loops" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match mdal_loops_json ~config:state.Mcp_server.room_config req with
         | Ok json -> Http.Response.json (Yojson.Safe.to_string json) reqd
         | Error msg ->
             Http.Response.json ~status:`Bad_request
               (Yojson.Safe.to_string (mdal_loops_error_json msg)) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_snapshot_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_summary_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/help" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = command_plane_help_http_json () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/topology" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_topology_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/units" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_units_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/operations" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_operations_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/detachments" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_detachments_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/detachment-status" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match command_plane_detachment_status_http_json ~state req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~compress:true ~status:`Bad_request ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/decisions" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_decisions_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/capacity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_capacity_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/alerts" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_alerts_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/traces" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_traces_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/swarm" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_swarm_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/chains/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match command_plane_chain_summary_http_json ~state req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~status:(chain_http_error_status message) ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/chains/events" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         command_plane_chain_events_http ~request:req reqd
       ) request reqd)

  |> Http.Router.prefix_get "/api/v1/chains/runs/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let req_path = Http.Request.path req in
         let prefix = "/api/v1/chains/runs/" in
         let run_id =
           String.sub req_path (String.length prefix)
             (String.length req_path - String.length prefix)
         in
         match command_plane_chain_run_http_json ~state req run_id with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~status:(chain_http_error_status message) ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/command-plane/units" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_define_http_json ~state req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/units/reparent" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_reparent_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/units/reassign" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_reassign_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_start_http_json ~state req ~args with
             | Ok json ->
                 respond_json_with_cors ~status:`Created request reqd
                   (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/pause" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_pause_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/resume" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_resume_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/stop" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_stop_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/finalize" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_finalize_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/checkpoint" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match
               command_plane_operation_checkpoint_http_json ~state req ~args
             with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/plan" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_plan_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/assign" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_assign_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/rebalance" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_rebalance_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/escalate" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_escalate_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/recall" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_recall_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/tick" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_tick_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/policy" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_policy_status_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/approve" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_approve_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/deny" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_deny_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/update" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_update_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/freeze" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_freeze_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/kill-switch" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_kill_switch_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.get "/api/v1/operator" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = operator_snapshot_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/operator/digest" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match operator_digest_http_json ~state ~sw ~clock req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
         | Error message ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json message))
       ) request reqd)

  |> Http.Router.post "/api/v1/operator/action" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_action_http_json ~state ~sw ~clock req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (operator_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/operator/confirm" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_confirm_http_json ~state ~sw ~clock req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (operator_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/council/debates" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json = council_debates_json req ~base_path in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/council/sessions" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = council_sessions_json req in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let hearth = query_param req "hearth" in
         let sort_by = board_sort_order_of_request req in
         let exclude_system = bool_query_param req "exclude_system" ~default:false in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let offset = int_query_param req "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
         let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
         let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
         let posts = filter_board_posts ~exclude_system posts in
         let karma_map = Board_dispatch.get_all_karma () in
         let get_karma author =
           try List.assoc author karma_map with Not_found -> 0
         in
         let paged = posts |> drop offset |> take limit in
         let posts_json =
           List.map
             (fun (p : Board.post) ->
               let author = Board.Agent_id.to_string p.author in
               board_post_dashboard_json ~author_karma:(get_karma author) p)
             paged
         in
         let json = `Assoc [
           ("posts", `List posts_json);
           ("count", `Int (List.length posts_json));
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("sort_by", `String (board_sort_label sort_by));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/hearths" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let hearths = Board_dispatch.list_hearths () in
         let json = `Assoc [
           ("hearths", `List (List.map (fun (name, count) ->
             `Assoc [("name", `String name); ("count", `Int count)]
           ) hearths));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/flairs" (fun _request reqd ->
       let flairs = List.map Board.flair_to_yojson Board.available_flairs in
       let json = `Assoc [("flairs", `List flairs)] in
       Http.Response.json (Yojson.Safe.to_string json) reqd)


  (* Board write APIs — used by Bevy Viewer *)
  |> Http.Router.post "/api/v1/tools/masc_board_vote" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let (ok, msg) = Tool_board.handle_tool "masc_board_vote" args in
             let status = if ok then `OK else `Bad_request in
             respond_json_with_cors ~status request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool ok); ("message", `String msg)
               ]))
           with exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("message", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/tools/masc_board_comment" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let (ok, msg) = Tool_board.handle_tool "masc_board_comment" args in
             let status = if ok then `Created else `Bad_request in
             respond_json_with_cors ~status request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool ok); ("message", `String msg)
               ]))
           with exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("message", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/karma" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let karma_list = Board_dispatch.get_all_karma () in
         let sorted = List.sort (fun (_, a) (_, b) -> compare b a) karma_list in
         let json = `Assoc [
           ("karma", `List (List.map (fun (agent, k) ->
             `Assoc [("agent", `String agent); ("karma", `Int k)]
           ) sorted));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Lodge Agents REST API — GET public, POST admin *)
  |> Http.Router.add ~path:"/api/v1/lodge/agents" ~methods:[`GET; `POST]
       ~handler:(fun request reqd ->
         match request.Httpun.Request.meth with
         | `GET ->
           with_public_read (fun _state _req reqd ->
             match Masc_mcp.Lodge_heartbeat.load_lodge_agents_full () with
             | Ok json ->
                 Http.Response.json (Yojson.Safe.to_string json) reqd
             | Error msg ->
                 Http.Response.json ~status:`Internal_server_error
                   (Printf.sprintf {|{"error":"%s"}|} msg) reqd
           ) request reqd
         | `POST ->
           with_admin_auth (fun _state _req reqd ->
             Http.Request.read_body_async reqd (fun body_str ->
               try
                 let json = Yojson.Safe.from_string body_str in
                 let open Yojson.Safe.Util in
                 let name = json |> member "name" |> to_string in
                 let emoji = json |> member "emoji" |> to_string in
                 let korean_name =
                   match json |> member "koreanName" with
                   | `String s -> Some s | _ -> None
                 in
                 let traits =
                   json |> member "traits" |> to_list |> List.map to_string
                 in
                 let interests =
                   try json |> member "interests" |> to_list
                       |> List.map to_string
                   with Yojson.Safe.Util.Type_error _ | Not_found -> []
                 in
                 let activity_level =
                   match json |> member "activityLevel" with
                   | `Float f -> f | `Int i -> float_of_int i | _ -> 0.7
                 in
                 let preferred_hours =
                   json |> member "preferredHours" |> to_list
                   |> List.map to_int
                 in
                 let peak_hour =
                   match json |> member "peakHour" with
                   | `Int i -> Some i | _ -> None
                 in
                 let model =
                   match json |> member "model" with
                   | `String s -> s | _ -> "glm-4.7-flash:latest"
                 in
                 let personality_hint =
                   match json |> member "personalityHint" with
                   | `String s -> Some s | _ -> None
                 in
                 let primary_value =
                   match json |> member "primaryValue" with
                   | `String s -> Some s | _ -> None
                 in
                 let name_re = Str.regexp "^[a-z][a-z0-9-]*$" in
                 let name_len = String.length name in
                 if name_len < 2 || name_len > 20
                    || not (Str.string_match name_re name 0) then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"name: 2-20 lowercase + hyphens"}|} reqd
                 else if String.length emoji = 0 then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"emoji is required"}|} reqd
                 else if traits = [] then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"at least one trait required"}|} reqd
                 else if preferred_hours = [] then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"at least one preferredHour"}|} reqd
                 else if activity_level < 0.1 || activity_level > 1.0 then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"activityLevel: 0.1-1.0"}|} reqd
                 else if List.exists (fun h -> h < 0 || h > 23)
                           preferred_hours then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"hours: 0-23"}|} reqd
                 else begin
                   match Masc_mcp.Lodge_heartbeat.create_agent_graphql
                           ~name ~emoji ~korean_name ~traits ~interests
                           ~activity_level ~preferred_hours ~peak_hour
                           ~model ~personality_hint ~primary_value () with
                   | Ok agent_json ->
                       Http.Response.json ~status:`Created
                         (Yojson.Safe.to_string (`Assoc [
                           ("ok", `Bool true);
                           ("agent", agent_json);
                         ])) reqd
                   | Error msg ->
                       Http.Response.json ~status:`Internal_server_error
                         (Printf.sprintf {|{"error":"%s"}|} msg) reqd
                 end
               with
               | Yojson.Safe.Util.Type_error (msg, _) ->
                   Http.Response.json ~status:`Bad_request
                     (Printf.sprintf {|{"error":"Invalid: %s"}|} msg)
                     reqd
               | Yojson.Json_error msg ->
                   Http.Response.json ~status:`Bad_request
                     (Printf.sprintf {|{"error":"Bad JSON: %s"}|} msg)
                     reqd
               | e ->
                   Http.Response.json ~status:`Internal_server_error
                     (Printf.sprintf {|{"error":"%s"}|}
                       (Printexc.to_string e)) reqd
             )
           ) request reqd
         | _ -> Http.Response.method_not_allowed reqd)

(** Extended router to handle OPTIONS *)
let make_extended_handler routes =
  fun _client_addr gluten_reqd ->
    let reqd = gluten_reqd.Gluten.Reqd.reqd in
    let request = Httpun.Reqd.request reqd in
    try
      let path = Http.Request.path request in
      let is_mcp_like =
        String.equal path "/mcp"
        || String.equal path "/mcp/operator"
        || String.equal path "/sse"
        || String.equal path "/messages"
      in
      let session_id_for_version = get_session_id_any request in
      let protocol_version =
        get_protocol_version_for_session ?session_id:session_id_for_version request
      in
      let origin = get_origin request in
      if is_mcp_like && not (validate_origin request) then
        let body = json_rpc_error (-32600) "Invalid origin" in
        let headers = Httpun.Headers.of_list (
          ("content-length", string_of_int (String.length body))
          :: json_headers "-" protocol_version origin
        ) in
        let response = Httpun.Response.create ~headers `Forbidden in
        Httpun.Reqd.respond_with_string reqd response body
      else if is_mcp_like && request.meth <> `OPTIONS &&
              not (is_valid_protocol_version protocol_version) then
        let body = json_rpc_error (-32600) "Unsupported protocol version" in
        let headers = Httpun.Headers.of_list (
          ("content-length", string_of_int (String.length body))
          :: json_headers "-" protocol_version origin
        ) in
        let response = Httpun.Response.create ~headers `Bad_request in
        Httpun.Reqd.respond_with_string reqd response body
      else
        match request.meth, path with
        | `OPTIONS, _ -> options_handler request reqd
        | `DELETE, "/mcp" -> handle_delete_mcp request reqd
        | `DELETE, "/mcp/operator" ->
            handle_delete_mcp ~profile:Mcp_eio.Operator_remote request reqd
        | `GET, "/api/v1/board/flairs" ->
            let flairs = List.map Board.flair_to_yojson Board.available_flairs in
            let json = `Assoc [("flairs", `List flairs)] in
            Http.Response.json (Yojson.Safe.to_string json) reqd
        | `GET, "/api/v1/board/hearths" ->
            let hearths = Board_dispatch.list_hearths () in
            let json = `Assoc [
              ("hearths", `List (List.map (fun (name, count) ->
                `Assoc [("name", `String name); ("count", `Int count)]
              ) hearths));
            ] in
            Http.Response.json (Yojson.Safe.to_string json) reqd
        | `GET, p
          when String.length p > 32
               && String.length p >= 24 + 8
               && String.sub p 0 24 = "/api/v1/council/debates/"
               && String.ends_with ~suffix:"/summary" p ->
            (match !server_state with
             | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
             | Some state ->
                 let prefix_len = 24 in
                 let suffix_len = 8 in
                 let debate_id_len = String.length p - prefix_len - suffix_len in
                 if debate_id_len <= 0 then
                   Http.Response.json ~status:`Bad_request {|{"error":"debate_id missing"}|} reqd
                 else
                   let debate_id = String.sub p prefix_len debate_id_len in
                   let base_path = state.Mcp_server.room_config.base_path in
                   let (status, json) = council_debate_summary_json ~base_path ~debate_id in
                   Http.Response.json ~status (Yojson.Safe.to_string json) reqd)
        | `GET, p
          when String.length p > 33
               && String.length p >= 25 + 8
               && String.sub p 0 25 = "/api/v1/council/sessions/"
               && String.ends_with ~suffix:"/summary" p ->
            (match !server_state with
             | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
             | Some state ->
                 let prefix_len = 25 in
                 let suffix_len = 8 in
                 let session_id_len = String.length p - prefix_len - suffix_len in
                 if session_id_len <= 0 then
                   Http.Response.json ~status:`Bad_request {|{"error":"session_id missing"}|} reqd
                 else
                   let session_id = String.sub p prefix_len session_id_len in
                   let base_path = state.Mcp_server.room_config.base_path in
                   let (status, json) = council_session_summary_json ~base_path ~session_id in
                   Http.Response.json ~status (Yojson.Safe.to_string json) reqd)
        | `GET, p when String.length p > 14 && String.sub p 0 14 = "/api/v1/board/" ->
            let post_id = String.sub p 14 (String.length p - 14) in
            let format = Option.value ~default:"nested" (query_param request "format") in
            let (status, body) = board_post_detail_json ~response_format:format ~post_id in
            Http.Response.json ~status body reqd
        | _ -> Http.Router.dispatch routes request reqd
    with exn ->
      let msg = Printexc.to_string exn in
      Http.Response.internal_error msg reqd

(** Main server loop *)
let run_server ~sw ~env ~port ~base_path =
  (* Extract components from Eio environment *)
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let net = Eio.Stdenv.net env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let fs = Eio.Stdenv.fs env in

  (* Set net and clock references in Mcp_eio for async operations *)
  Mcp_eio.set_net net;
  Mcp_eio.set_clock clock;
  Masc_mcp.Eio_context.set_switch sw;
  Masc_mcp.Eio_context.set_net net;
  Masc_mcp.Eio_context.set_clock clock;
  Council.Thread_persist.set_eio_context ~clock
    ~https_connector:(Masc_mcp.Eio_context.get_https_connector ())
    net;
  Masc_mcp.Process_eio.init
    ~cwd_default:Eio.Path.(fs / base_path)
    ~proc_mgr ~clock;

  (* Create Caqti-compatible stdenv adapter
     Note: net type coercion from [Generic|Unix] to [Generic] is safe
     because Caqti only uses the generic network capabilities *)
  let caqti_env : Caqti_eio.stdenv = object
    method net = (net :> [`Generic] Eio.Net.ty Eio.Resource.t)
    method clock = clock
    method mono_clock = mono_clock
  end in

  Unix.putenv "MASC_BASE_PATH_INPUT" base_path;

  (* Initialize server state with Eio context *)
  let state = Mcp_eio.create_state_eio ~sw ~env:caqti_env ~proc_mgr ~fs ~clock ~net ~base_path in
  server_state := Some state;
  Masc_mcp.Chain_native_eio.configure_storage_paths state.room_config;
  (try Masc_mcp.Tool_command_plane.backfill_chain_overlays state.room_config
   with exn ->
     Printf.eprintf "[chain-backfill] startup backfill failed: %s\n%!"
       (Printexc.to_string exn));
  Mcp_server.set_sse_callback state Sse.broadcast;

  (* Keepers are meant to be long-lived. Start their keepalive fibers on startup
     so liveness/last_seen stays up-to-date even if no tool calls happen. *)
  (try
     let keeper_ctx : _ Tool_keeper.context = { config = state.room_config; sw; clock } in
     let stats = Tool_keeper.bootstrap_existing_keepers keeper_ctx in
     if stats.enabled then
       Printf.eprintf
         "[keeper-bootstrap] scanned=%d started=%d stale=%d\n%!"
         stats.scanned stats.started stats.stale
   with exn -> Printf.eprintf "[main] keeper bootstrap failed: %s\n%!" (Printexc.to_string exn));

  (* Initialize Task backend - share pool with Board if PostgreSQL available *)
  (match Board_dispatch.get_pg_pool () with
   | Some pool ->
       (match Task_dispatch.init_pg pool with
        | Ok () -> Printf.eprintf "[Task_dispatch] PostgreSQL backend initialized\n%!"
        | Error e -> Printf.eprintf "[Task_dispatch] PG init failed: %s, using JSONL\n%!" (Types.show_masc_error e))
   | None -> Task_dispatch.init_jsonl ());
  Progress.set_sse_callback Sse.broadcast;
  let cancel_orchestrator = Masc_mcp.Orchestrator.start ~sw ~proc_mgr ~clock ~domain_mgr state.room_config in
  (* Store cancel function for graceful shutdown *)
  Masc_mcp.Shutdown_hooks.register_cancel_orchestrator cancel_orchestrator;
  (* Lodge world heartbeat - wakes agents every 60s *)
  Masc_mcp.Lodge_heartbeat.start ~sw ~clock state.room_config;
  (* Gardener — self-organizing agent ecosystem (task-aware, LLM-primary) *)
  Masc_mcp.Gardener.start ~sw ~clock ~room_config:state.room_config;
  (* Internal guardian loops (no external watchdog dependency) *)
  Masc_mcp.Guardian.start ~sw ~clock ~net state.room_config;
  Masc_mcp.Dashboard_governance_judge.start ~sw ~clock
    ~base_path:state.room_config.base_path
    ~build_facts:(fun () ->
      Masc_mcp.Dashboard_governance.factual_snapshot_json
        ~base_path:state.room_config.base_path)
    ();
  (* Start MCP session cleanup loop *)
  Masc_mcp.Session.start_mcp_session_cleanup_loop ~sw ~clock ();

  (* Board Listener — bridges pg_notify to SSE for real-time updates (Phase C) *)
  (match Board_dispatch.get_pg_pool () with
   | Some pool ->
       let listener = Board_listener.create pool in
       Eio.Fiber.fork ~sw (fun () -> Board_listener.start listener);
       Printf.eprintf "[Board_listener] Fiber started for real-time Board events\n%!"
   | None ->
       Printf.eprintf "[Board_listener] Skipped (not using PostgreSQL backend)\n%!");

  (* Periodic SSE stale-client reaper — every 60s, evict connections older than 30min *)
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock 60.0;
      let stale_sids = Masc_mcp.Sse.cleanup_stale () in
      List.iter stop_sse_session stale_sids;
      if stale_sids <> [] then
        Printf.eprintf "[SSE] Reaped %d stale connections (active: %d)\n%!"
          (List.length stale_sids) (Masc_mcp.Sse.client_count ());
      loop ()
    in
    loop ());

  let config = { Http.default_config with port; host = "0.0.0.0" } in
  Unix.putenv "MASC_HTTP_PORT" (string_of_int config.port);
  (match Sys.getenv_opt "MASC_HTTP_BASE_URL" with
   | Some existing when String.trim existing <> "" -> ()
   | _ ->
       Unix.putenv "MASC_HTTP_BASE_URL"
         (Printf.sprintf "http://127.0.0.1:%d" config.port));
  let routes = make_routes ~port:config.port ~host:config.host ~sw ~clock in
  let request_handler = make_extended_handler routes in

  (* Listen on all interfaces for Cloudflare tunnel access *)
  let ip = Eio.Net.Ipaddr.V4.any in
  let addr = `Tcp (ip, config.port) in
  let socket = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:config.max_connections addr in

  let resolved_base = state.room_config.base_path in
  let masc_dir = Filename.concat resolved_base ".masc" in

  (* Initialize A2A subscription persistence *)
  Masc_mcp.A2a_tools.init ~masc_dir;

  Printf.printf "🚀 MASC MCP Server listening on http://%s:%d\n%!" config.host config.port;
  Printf.printf "   Base path: %s\n%!" resolved_base;
  if resolved_base <> base_path then
    Printf.printf "   Base path (input): %s\n%!" base_path;
  Printf.printf "   MASC dir: %s\n%!" masc_dir;
  Printf.printf "   GET  /mcp → SSE stream (notifications)\n%!";
  Printf.printf
    "   POST /mcp → JSON-RPC (Accept: application/json, text/event-stream)\n\
     %!";
  Printf.printf "   DELETE /mcp → Session termination\n%!";
  Printf.printf
    "   GET  /mcp/operator → Remote operator MCP stream (bearer token required)\n\
     %!";
  Printf.printf
    "   POST /mcp/operator → Remote operator JSON-RPC (4 curated tools only)\n\
     %!";
  Printf.printf
    "   DELETE /mcp/operator → Remote operator session termination\n%!";
  Printf.printf "   POST /graphql → GraphQL (read-only)\n%!";
  Printf.printf
    "   GET  /sse → legacy SSE stream (deprecated; use /mcp)\n%!";
  Printf.printf
    "   POST /messages → legacy client->server messages (deprecated)\n%!";
  Printf.printf "   GET  /health → Health check\n%!";

  (* Defer Lodge init slightly to avoid startup race when GRAPHQL_URL points
     to local /graphql on this same process. *)
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Time.sleep clock 1.0;
    Masc_mcp.Tool_lodge.init ());

  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  (* ═══════════════════════════════════════════════════════════════════════
     HTTP/2 Response Helpers - Reduce duplication in handlers
     ═══════════════════════════════════════════════════════════════════════ *)

  let h2_respond_json ?(status = `OK) ?(extra_headers = []) h2_reqd body =
    let headers = H2.Headers.of_list ([
      ("content-type", "application/json; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_text ?(status = `OK) ?(extra_headers = []) h2_reqd body =
    let headers = H2.Headers.of_list ([
      ("content-type", "text/plain; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_html ?(status = `OK) ?(extra_headers = []) h2_reqd body =
    let headers = H2.Headers.of_list ([
      ("content-type", "text/html; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_bytes
      ?(status = `OK)
      ?(extra_headers = [])
      ~content_type
      h2_reqd
      body =
    let headers = H2.Headers.of_list ([
      ("content-type", content_type);
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_empty ?(status = `No_content) ?(extra_headers = []) h2_reqd =
    let headers = H2.Headers.of_list (("content-length", "0") :: extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.close writer
  in

  (* Read H2 request body asynchronously *)
  let h2_read_body h2_reqd callback =
    let body = H2.Reqd.request_body h2_reqd in
    let buf = Buffer.create 4096 in
    let rec read_loop () =
      H2.Body.Reader.schedule_read body
        ~on_eof:(fun () -> callback (Buffer.contents buf))
        ~on_read:(fun bigstring ~off ~len ->
          let chunk = Bigstringaf.substring bigstring ~off ~len in
          Buffer.add_string buf chunk;
          read_loop ())
    in
    read_loop ()
  in

  (* HTTP/2 error handler *)
  let _h2_error_handler _client_addr ?request:_ error respond =
    let message = match error with
      | `Exn exn -> Printexc.to_string exn
      | `Bad_request -> "Bad request"
      | `Internal_server_error -> "Internal server error"
    in
    Printf.eprintf "[H2] Error: %s\n%!" message;
    let headers = H2.Headers.of_list [("content-type", "text/plain")] in
    let body = respond headers in
    H2.Body.Writer.write_string body message;
    H2.Body.Writer.close body
  in

  (* ═══════════════════════════════════════════════════════════════════════
     HTTP/2 Request Handler - Full implementation
     ═══════════════════════════════════════════════════════════════════════ *)
  let _h2_request_handler _client_addr h2_reqd =
    let h2_req = H2.Reqd.request h2_reqd in
    let h2_headers = h2_req.headers in
    (* Convert H2.Request to Httpun.Request for compatibility with existing code *)
    let httpun_headers = Httpun.Headers.of_list (H2.Headers.to_list h2_headers) in
    let httpun_meth = match h2_req.meth with
      | `GET -> `GET | `POST -> `POST | `DELETE -> `DELETE
      | `OPTIONS -> `OPTIONS | `PUT -> `PUT | `HEAD -> `HEAD
      | `CONNECT -> `CONNECT | `TRACE -> `TRACE | `Other s -> `Other s
    in
    let httpun_request = Httpun.Request.create ~headers:httpun_headers httpun_meth h2_req.target in
    let path = Http.Request.path httpun_request in
    let origin = match H2.Headers.get h2_headers "origin" with
      | Some o -> o | None -> "*"
    in
    let cors = cors_headers origin in
    let base_path =
      match !server_state with
      | Some s -> s.Mcp_server.room_config.base_path
      | None -> default_base_path ()
    in
    let session_id_opt = get_session_id_any httpun_request in
    let h2_respond_dashboard_index () =
      let index_path = dashboard_index_path () in
      match read_file index_path with
      | Ok body ->
          let etag_value = "\"" ^ dashboard_etag () ^ "\"" in
          let if_none_match = H2.Headers.get h2_headers "if-none-match" in
          (match if_none_match with
           | Some inm when String.equal inm etag_value ->
               let resp_headers = H2.Headers.of_list ([
                 ("etag", etag_value); ("cache-control", dashboard_index_cache_control);
               ] @ cors) in
               let response = H2.Response.create ~headers:resp_headers `Not_modified in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.close writer
           | _ ->
               let extra = [("etag", etag_value); ("cache-control", dashboard_index_cache_control); ("vary", "Accept-Encoding")] @ cors in
               h2_respond_html h2_reqd body ~extra_headers:extra)
      | Error _ ->
          h2_respond_html h2_reqd "<html><body>Dashboard build not found. Run: cd dashboard &amp;&amp; npm run build</body></html>" ~extra_headers:cors
    in

    let dispatch_h2_route () =
      match httpun_meth, path with
      (* ─────────────────────────────────────────────────────────────────────
         Health & Metrics
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/health" ->
          let uptime_secs = int_of_float (Unix.gettimeofday () -. server_start_time) in
          let uptime_str =
            if uptime_secs < 60 then Printf.sprintf "%ds" uptime_secs
            else if uptime_secs < 3600 then Printf.sprintf "%dm %ds" (uptime_secs / 60) (uptime_secs mod 60)
            else Printf.sprintf "%dh %dm" (uptime_secs / 3600) ((uptime_secs mod 3600) / 60)
          in
          let build = Build_identity.current () in
          let lodge_json = Masc_mcp.Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
          let guardian_json = Masc_mcp.Guardian.status_json () in
          let sentinel_json = Masc_mcp.Sentinel.status_json () in
          let health_json = `Assoc [
            ("status", `String "ok");
            ("server", `String "masc-mcp");
            ("version", `String build.release_version);
            ("release_version", `String build.release_version);
            ("build", Build_identity.to_yojson build);
            ("protocol", `String "h2");
            ("uptime", `String uptime_str);
            ("sse_clients", `Int (Sse.client_count ()));
            ("lodge", lodge_json);
            ("guardian", guardian_json);
            ("sentinel", sentinel_json);
          ] in
          let body = Yojson.Safe.to_string health_json in
          h2_respond_json h2_reqd body ~extra_headers:cors

      | `GET, "/metrics" ->
          let body = Masc_mcp.Prometheus.to_prometheus_text () in
          let headers = H2.Headers.of_list ([
            ("content-type", "text/plain; version=0.0.4; charset=utf-8");
            ("content-length", string_of_int (String.length body));
          ] @ cors) in
          let response = H2.Response.create ~headers `OK in
          let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
          H2.Body.Writer.write_string writer body;
          H2.Body.Writer.close writer

      | `GET, "/" ->
          h2_respond_text h2_reqd "MASC MCP Server (HTTP/2)" ~extra_headers:cors

      | `GET, "/favicon.ico" | `GET, "/favicon.svg" ->
          h2_respond_bytes
            h2_reqd
            favicon_svg
            ~content_type:"image/svg+xml"
            ~extra_headers:cors

      (* ─────────────────────────────────────────────────────────────────────
         CORS Preflight
         ───────────────────────────────────────────────────────────────────── *)
      | `OPTIONS, _ ->
          h2_respond_empty h2_reqd ~extra_headers:(cors_preflight_headers origin)

      (* ─────────────────────────────────────────────────────────────────────
         MCP Endpoints
         ───────────────────────────────────────────────────────────────────── *)
      | `POST, "/mcp" | `POST, "/" | `POST, "/mcp/operator" ->
          let session_id = match session_id_opt with
            | Some id -> id
            | None -> Mcp_session.generate ()
          in
          let auth_token = auth_token_from_request httpun_request in
          let protocol_version = get_protocol_version_for_session ~session_id httpun_request in
          let profile =
            if String.equal path "/mcp/operator" then Mcp_eio.Operator_remote
            else Mcp_eio.Full
          in
          (* HTTP-level auth check for MCP endpoints *)
          let base_path = match !server_state with
            | Some s -> s.Mcp_server.room_config.base_path
            | None -> default_base_path ()
          in
          let auth_result =
            match profile with
            | Mcp_eio.Full -> verify_mcp_auth ~base_path httpun_request
            | Mcp_eio.Operator_remote ->
                verify_operator_mcp_auth ~base_path httpun_request
          in
          (match validate_mcp_session_profile ~profile session_id with
           | Error msg ->
               let body = json_rpc_error (-32600) msg in
               h2_respond_json h2_reqd body ~status:`Conflict ~extra_headers:cors
           | Ok () ->
               remember_mcp_profile session_id profile;
               (match auth_result with
                | Error msg ->
                    let body = Printf.sprintf {|{"jsonrpc":"2.0","error":{"code":-32001,"message":"%s"}}|} msg in
                    h2_respond_json h2_reqd body ~status:`Unauthorized ~extra_headers:(("www-authenticate", "Bearer") :: cors)
                | Ok _cred_opt -> (
                    match classify_mcp_accept httpun_request with
                    | Http_negotiation.Rejected ->
                        let body =
                          json_rpc_error (-32600)
                            "Invalid Accept header: must include application/json and text/event-stream. \
                             Set MASC_ALLOW_LEGACY_ACCEPT=1 for temporary compatibility."
                        in
                        h2_respond_json h2_reqd body ~status:`Bad_request
                          ~extra_headers:(cors @ mcp_headers session_id protocol_version)
                    | accept_mode ->
                        let accept_warn_headers =
                          legacy_accept_warning_headers accept_mode
                        in
                        h2_read_body h2_reqd (fun body_str ->
                            let state = get_server_state ()
                            in
                            let response_json =
                              Mcp_eio.handle_request ~clock ~sw ~profile
                                ~mcp_session_id:session_id ?auth_token state body_str
                            in
                            (match protocol_version_from_body body_str with
                            | Some v -> remember_protocol_version session_id v
                            | None -> ());
                            let protocol_version =
                              get_protocol_version_for_session ~session_id
                                httpun_request
                            in
                            let mcp_hdrs =
                              accept_warn_headers @ mcp_headers session_id protocol_version
                              @ cors
                            in
                            match response_json with
                            | `Null ->
                                h2_respond_empty h2_reqd ~status:`Accepted
                                  ~extra_headers:mcp_hdrs
                            | json when is_http_error_response json ->
                                let body = Yojson.Safe.to_string json in
                                h2_respond_json h2_reqd body ~status:`Bad_request
                                  ~extra_headers:mcp_hdrs
                            | json ->
                                let body = Yojson.Safe.to_string json in
                                h2_respond_json h2_reqd body ~extra_headers:mcp_hdrs))))

      | `DELETE, "/mcp" | `DELETE, "/mcp/operator" ->
          let profile =
            if String.equal path "/mcp/operator" then Mcp_eio.Operator_remote
            else Mcp_eio.Full
          in
          let base_path = match !server_state with
            | Some s -> s.Mcp_server.room_config.base_path
            | None -> default_base_path ()
          in
          let auth_result =
            match profile with
            | Mcp_eio.Full -> Ok None
            | Mcp_eio.Operator_remote ->
                verify_operator_mcp_auth ~base_path httpun_request
          in
          (match auth_result with
           | Error msg ->
               let body =
                 Printf.sprintf {|{"jsonrpc":"2.0","error":{"code":-32001,"message":"%s"}}|} msg
               in
               h2_respond_json h2_reqd body ~status:`Unauthorized
                 ~extra_headers:(("www-authenticate", "Bearer") :: cors)
           | Ok _ ->
               (match session_id_opt with
                | Some session_id -> (
                    match validate_mcp_session_delete_profile ~profile session_id with
                    | Error msg ->
                        let body =
                          Printf.sprintf {|{"jsonrpc":"2.0","error":{"code":-32600,"message":"%s"}}|} msg
                        in
                        h2_respond_json h2_reqd body ~status:`Conflict
                          ~extra_headers:cors
                    | Ok () ->
                        stop_sse_session session_id;
                        Sse.unregister session_id;
                        forget_mcp_session session_id;
                        Printf.printf "🔚 Session terminated: %s\n%!" session_id;
                        let mcp_hdrs = mcp_headers session_id (get_protocol_version httpun_request) in
                        h2_respond_empty h2_reqd ~extra_headers:mcp_hdrs)
                | None ->
                    h2_respond_text h2_reqd "Mcp-Session-Id required" ~status:`Bad_request ~extra_headers:cors))

      (* ─────────────────────────────────────────────────────────────────────
         Dashboard
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/dashboard" | `GET, "/dashboard/" ->
          h2_respond_dashboard_index ()

      | `GET, "/dashboard/credits" ->
          h2_respond_html h2_reqd (Masc_mcp.Credits_dashboard.html ()) ~extra_headers:cors

      | `GET, "/dashboard/lodge" ->
          let etag_value = "\"" ^ Masc_mcp.Lodge_dashboard.etag () ^ "\"" in
          let if_none_match = H2.Headers.get h2_headers "if-none-match" in
          (match if_none_match with
           | Some inm when String.equal inm etag_value ->
               let resp_headers = H2.Headers.of_list ([
                 ("etag", etag_value); ("cache-control", dashboard_index_cache_control);
               ] @ cors) in
               let response = H2.Response.create ~headers:resp_headers `Not_modified in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.close writer
           | _ ->
               let body = Masc_mcp.Lodge_dashboard.html () in
               let extra = [("etag", etag_value); ("cache-control", dashboard_index_cache_control)] @ cors in
               h2_respond_html h2_reqd body ~extra_headers:extra)

      | `GET, p when is_dashboard_spa_deep_link p ->
          h2_respond_dashboard_index ()

      (* ─────────────────────────────────────────────────────────────────────
         GraphQL
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/graphql" ->
          let nonce =
            let rng = Random.State.make_self_init () in
            let bytes = Bytes.init 16 (fun _ -> Char.chr (Random.State.int rng 256)) in
            Base64.encode_string (Bytes.to_string bytes)
          in
          let csp_header = ("content-security-policy", graphql_csp_header nonce) in
          h2_respond_html h2_reqd (graphql_playground_html ~nonce) ~extra_headers:(csp_header :: cors)

      | `POST, "/graphql" ->
          h2_read_body h2_reqd (fun body_str ->
            let state = get_server_state ()
            in
            let response = Graphql_api.handle_request ~config:state.room_config body_str in
            let status = match response.status with `OK -> `OK | `Bad_request -> `Bad_request in
            h2_respond_json h2_reqd response.body ~status ~extra_headers:cors
          )

      (* ─────────────────────────────────────────────────────────────────────
         REST API
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/api/v1/dashboard" ->
          let json =
            `Assoc
              [
                ("error", `String "dashboard batch contract removed");
                ("message", `String "Use /api/v1/dashboard/shell and surface-specific projection endpoints.");
              ]
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json)
            ~status:`Gone ~extra_headers:cors

      | `GET, "/api/v1/dashboard/shell" ->
          let state = get_server_state () in
          let json = dashboard_shell_http_json state.Mcp_server.room_config in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/execution" ->
          let state = get_server_state () in
          let json = dashboard_execution_http_json ~state ~sw ~clock httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/memory" ->
          let json = dashboard_memory_http_json httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/governance" ->
          let state = get_server_state () in
          let json =
            dashboard_governance_http_json httpun_request
              ~base_path:state.Mcp_server.room_config.base_path
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/planning" ->
          let state = get_server_state () in
          let json =
            dashboard_planning_http_json httpun_request
              ~config:state.Mcp_server.room_config
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/semantics" ->
          let json = dashboard_semantics_http_json () in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/mission" ->
          let state = get_server_state () in
          let json = dashboard_mission_http_json ~state ~sw ~clock httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/mission/briefing" ->
          let state = get_server_state () in
          let json =
            dashboard_mission_briefing_http_json ~state ~sw ~clock
              httpun_request
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/proof" ->
          let state = get_server_state () in
          let json = dashboard_proof_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/mdal/loops" ->
          let state = get_server_state () in
          (match mdal_loops_json ~config:state.Mcp_server.room_config httpun_request with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error msg ->
              h2_respond_json h2_reqd
                (Yojson.Safe.to_string (mdal_loops_error_json msg))
                ~status:`Bad_request ~extra_headers:cors)

      | `GET, "/api/v1/command-plane" ->
          let state = get_server_state () in
          let json = command_plane_snapshot_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/summary" ->
          let state = get_server_state () in
          let json = command_plane_summary_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/help" ->
          let json = command_plane_help_http_json () in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/topology" ->
          let state = get_server_state () in
          let json = command_plane_topology_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/units" ->
          let state = get_server_state () in
          let json = command_plane_units_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/operations" ->
          let state = get_server_state () in
          let json = command_plane_operations_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/detachments" ->
          let state = get_server_state () in
          let json = command_plane_detachments_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/detachment-status" ->
          let state = get_server_state () in
          (match command_plane_detachment_status_http_json ~state httpun_request with
           | Ok json ->
               h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                 ~extra_headers:cors
           | Error message ->
               h2_respond_json h2_reqd
                 (Yojson.Safe.to_string (command_plane_error_json message))
                 ~status:`Bad_request ~extra_headers:cors)

      | `GET, "/api/v1/command-plane/decisions" ->
          let state = get_server_state () in
          let json = command_plane_decisions_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/capacity" ->
          let state = get_server_state () in
          let json = command_plane_capacity_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/alerts" ->
          let state = get_server_state () in
          let json = command_plane_alerts_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/traces" ->
          let state = get_server_state () in
          let json = command_plane_traces_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/swarm" ->
          let state = get_server_state () in
          let json = command_plane_swarm_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/chains/summary" ->
          let state = get_server_state () in
          (match command_plane_chain_summary_http_json ~state httpun_request with
           | Ok json ->
               h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                 ~extra_headers:cors
           | Error message ->
               h2_respond_json h2_reqd
                 (Yojson.Safe.to_string (command_plane_error_json message))
                 ~status:(chain_http_error_status message) ~extra_headers:cors)

      | `GET, "/api/v1/chains/events" ->
          command_plane_chain_events_h2 ~request:httpun_request h2_reqd

      | `GET, path when String.length path > String.length "/api/v1/chains/runs/"
                        && String.sub path 0 (String.length "/api/v1/chains/runs/")
                           = "/api/v1/chains/runs/" ->
          let state = get_server_state () in
          let prefix_len = String.length "/api/v1/chains/runs/" in
          let run_id =
            String.sub path prefix_len (String.length path - prefix_len)
          in
          (match command_plane_chain_run_http_json ~state httpun_request run_id with
           | Ok json ->
               h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                 ~extra_headers:cors
           | Error message ->
               h2_respond_json h2_reqd
                 (Yojson.Safe.to_string (command_plane_error_json message))
                 ~status:(chain_http_error_status message) ~extra_headers:cors)
      | `GET, "/api/v1/command-plane/policy" ->
          let state = get_server_state () in
          let json = command_plane_policy_status_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/operator" ->
          let state = get_server_state () in
          let path = Http.Request.path httpun_request in
          if http_auth_strict_enabled () && not (is_public_read_path path) then
            (match authorize_read_request ~base_path:state.Mcp_server.room_config.base_path httpun_request with
             | Error err ->
                 let status = http_status_of_auth_error err in
                 h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
             | Ok () ->
                 let json = operator_snapshot_http_json ~state ~sw ~clock httpun_request in
                 h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)
          else
            let json = operator_snapshot_http_json ~state ~sw ~clock httpun_request in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
      | `GET, "/api/v1/operator/digest" ->
          let state = get_server_state () in
          let path = Http.Request.path httpun_request in
          let respond_digest () =
            match operator_digest_http_json ~state ~sw ~clock httpun_request with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
            | Error message ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (operator_error_json message))
                  ~status:`Bad_request ~extra_headers:cors
          in
          if http_auth_strict_enabled () && not (is_public_read_path path) then
            (match authorize_read_request ~base_path:state.Mcp_server.room_config.base_path httpun_request with
             | Error err ->
                 let status = http_status_of_auth_error err in
                 h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
             | Ok () -> respond_digest ())
          else
            respond_digest ()
      | `GET, "/api/v1/status" ->
          let state = get_server_state () in
          let config = state.Mcp_server.room_config in
          let room_state = Masc_mcp.Room.read_state config in
          let tempo = Masc_mcp.Tempo.get_tempo config in
          let json = `Assoc [
            ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
            ("project", `String room_state.project);
            ("tempo_interval_s", `Float tempo.current_interval_s);
            ("paused", `Bool room_state.paused);
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/credits" ->
          h2_respond_json h2_reqd (Masc_mcp.Credits_dashboard.json_api ()) ~extra_headers:cors

      | `GET, "/api/v1/trpg/events" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
          let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
          let event_type_filter = query_param httpun_request "event_type" in
          (match trpg_read_events_json ~base_dir ~room_id ~after_seq ~event_type_filter with
          | Ok json ->
              let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
              h2_respond_json h2_reqd (Yojson.Safe.to_string normalized) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/room/current" ->
          let state = get_server_state () in
          let config = state.Mcp_server.room_config in
          let room_id = Option.value ~default:"default" (Masc_mcp.Room.read_current_room config) in
          let json = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `POST, "/api/v1/room/current" ->
          let state = get_server_state () in
          let config = state.Mcp_server.room_config in
          h2_read_body h2_reqd (fun body_str ->
            try
              let json = Yojson.Safe.from_string body_str in
              (match trpg_parse_required_string "room_id" json with
               | Error (`Bad_request, msg) ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string (trpg_error_json msg))
                      ~status:`Bad_request ~extra_headers:cors
               | Ok room_id ->
                   let room_id = String.trim room_id in
                   if room_id = "" then
                     h2_respond_json h2_reqd
                       (Yojson.Safe.to_string (trpg_error_json "room_id cannot be empty"))
                       ~status:`Bad_request ~extra_headers:cors
                   else (
                     Masc_mcp.Room.write_current_room config room_id;
                     Masc_mcp.Room.ensure_room_entry config room_id;
                     let response = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
                     h2_respond_json h2_reqd (Yojson.Safe.to_string response) ~extra_headers:cors))
            with
            | Yojson.Json_error msg ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json (Printf.sprintf "invalid json: %s" msg)))
                  ~status:`Bad_request ~extra_headers:cors
            )

      | `POST, "/api/v1/operator/action" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match operator_action_http_json ~state ~sw ~clock httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (operator_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_unit_define_http_json ~state httpun_request
                        ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units/reparent" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_unit_reparent_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units/reassign" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_unit_reassign_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_operation_start_http_json ~state httpun_request
                        ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~status:`Created ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/checkpoint" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_operation_checkpoint_http_json ~state
                        httpun_request ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/pause" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_pause_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/resume" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_resume_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/stop" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_stop_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/finalize" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_finalize_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/plan" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_plan_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/assign" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_assign_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/rebalance" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_rebalance_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/escalate" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_escalate_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/recall" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_recall_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/tick" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_tick_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/approve" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_approve_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/deny" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_deny_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/update" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_update_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/freeze" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_freeze_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/kill-switch" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_kill_switch_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/operator/confirm" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match operator_confirm_http_json ~state ~sw ~clock httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (operator_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/trpg/events" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_append_event_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~status:`Created
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `GET, "/api/v1/trpg/state" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite" (query_param httpun_request "rule_module")
          in
          (match trpg_derive_state_json ~base_dir ~room_id ~rule_module with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/lobby/catalog" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          (match
             trpg_lobby_catalog_json ~base_dir ~config:state.Mcp_server.room_config
               ~room_id ~rule_module
           with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/lobby/preflight" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          let dm_keeper = query_param httpun_request "dm" in
          let player_keepers =
            query_param httpun_request "players" |> Option.value ~default:""
            |> split_csv_nonempty
          in
          let models =
            query_param httpun_request "models" |> Option.value ~default:""
            |> split_csv_nonempty
          in
          (match
             trpg_lobby_preflight_json ~base_dir ~config:state.Mcp_server.room_config
               ~room_id ~rule_module ~dm_keeper ~player_keepers ~models
           with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/overview" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          (match trpg_overview_json ~base_dir ~room_id ~rule_module with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/control/state" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          (match trpg_control_state_json ~base_dir ~room_id ~rule_module with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/models" ->
          h2_respond_json h2_reqd
            (Yojson.Safe.to_string (trpg_available_models_json ()))
            ~extra_headers:cors

      | `POST, "/api/v1/trpg/dice/roll" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_dice_roll_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~status:`Created
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `POST, "/api/v1/trpg/turns/advance" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_turn_advance_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `POST, "/api/v1/trpg/rounds/run" ->
          let state = get_server_state () in
          h2_read_body h2_reqd (fun body_str ->
            let agent_name =
              Option.value
                ~default:"dashboard"
                (agent_from_request httpun_request)
            in
            match Masc_mcp.Eio_context.get_switch_opt (), Masc_mcp.Eio_context.get_clock_opt () with
            | Some sw, Some clock -> (
                match
                  trpg_round_run_json
                    ~state
                    ~agent_name
                    ~sw
                    ~clock
                    ~idempotency_key:
                      (get_header_any_case httpun_request.headers "idempotency-key")
                    ~body_str
                with
                | Ok json ->
                    h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                      ~extra_headers:cors
                | Error (`Bad_request, msg) ->
                    h2_respond_json h2_reqd
                      (Yojson.Safe.to_string (trpg_error_json msg))
                      ~status:`Bad_request ~extra_headers:cors
                | Error (`Internal_server_error, msg) ->
                    h2_respond_json h2_reqd
                      (Yojson.Safe.to_string (trpg_error_json msg))
                      ~status:`Internal_server_error ~extra_headers:cors)
            | _ ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string
                     (trpg_error_json "trpg runtime not initialized"))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `GET, "/api/v1/trpg/stream" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
          let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
          let event_type_filter = query_param httpun_request "event_type" in
          (match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
          | Ok json ->
              let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
              h2_respond_json h2_reqd (Yojson.Safe.to_string normalized) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/timeline" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
          let event_type_filter = query_param httpun_request "event_type" in
          let actor_filter = query_param httpun_request "actor" in
          let phase_filter = query_param httpun_request "phase" in
          let limit =
            int_query_param httpun_request "limit" ~default:50
            |> clamp ~min_v:1 ~max_v:200
          in
          (match
             trpg_timeline_json ~base_dir ~room_id ~after_seq ~event_type_filter
               ~actor_filter ~phase_filter ~limit
           with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/stream/sse" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
          let event_type_filter = query_param httpun_request "event_type" in
          let room_id_trimmed = String.trim room_id in
          if room_id_trimmed = "" then
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json "room_id is required"))
              ~status:`Bad_request ~extra_headers:cors
          else begin
            match trpg_parse_event_type_filter event_type_filter with
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Ok event_type_opt ->
                let last_event_id =
                  match H2.Headers.get (H2.Reqd.request h2_reqd).headers "last-event-id" with
                  | Some id -> (try int_of_string id with Failure _ -> 0)
                  | None -> 0
                in
                let headers = H2.Headers.of_list ([
                  ("content-type", "text/event-stream");
                  ("cache-control", "no-cache");
                ] @ cors) in
                let response = H2.Response.create ~headers `OK in
                let writer = H2.Reqd.respond_with_streaming
                  ~flush_headers_immediately:true h2_reqd response in
                let closed = ref false in
                let last_seq = ref last_event_id in

                let send data =
                  if !closed || H2.Body.Writer.is_closed writer then begin
                    closed := true; false
                  end else begin
                    H2.Body.Writer.write_string writer data;
                    H2.Body.Writer.flush writer ignore;
                    true
                  end
                in

                let init_comment =
                  Printf.sprintf ": TRPG SSE stream for room %s (after_seq=%d)\nretry: 3000\n\n"
                    room_id_trimmed !last_seq in
                ignore (send init_comment);

                (* Send existing events *)
                (match
                   (if !last_seq > 0 then
                      Masc_mcp.Trpg_engine_store_sqlite.read_events_after
                        ~base_dir ~room_id:room_id_trimmed ~after_seq:!last_seq
                    else
                      Masc_mcp.Trpg_engine_store_sqlite.read_events
                        ~base_dir ~room_id:room_id_trimmed)
                 with
                 | Ok events ->
                     let events = match event_type_opt with
                       | None -> events
                       | Some et ->
                           List.filter (fun (ev : Masc_mcp.Trpg_engine_event.t) ->
                             ev.event_type = et) events
                     in
                     List.iter (fun ev ->
                       if not !closed then begin
                         ignore (send (trpg_event_to_sse ev));
                         last_seq := max !last_seq ev.Masc_mcp.Trpg_engine_event.seq
                       end) events
                 | Error _ -> ());

                (* Poll loop *)
                (match Masc_mcp.Eio_context.get_switch_opt (), Masc_mcp.Eio_context.get_clock_opt () with
                 | Some sw, Some clock ->
                     Eio.Fiber.fork ~sw (fun () ->
                       let is_cancelled = function
                         | Eio.Cancel.Cancelled _ -> true | _ -> false in
                       let keepalive_counter = ref 0 in
                       let polls_per_keepalive =
                         max 1 (int_of_float (trpg_sse_keepalive_s /. trpg_sse_poll_interval_s)) in
                       let rec loop () =
                         if not !closed then begin
                           (try Eio.Time.sleep clock trpg_sse_poll_interval_s
                            with exn -> if is_cancelled exn then raise exn);
                           if not !closed then begin
                             (match
                                Masc_mcp.Trpg_engine_store_sqlite.read_events_after
                                  ~base_dir ~room_id:room_id_trimmed ~after_seq:!last_seq
                              with
                              | Ok events ->
                                  let events = match event_type_opt with
                                    | None -> events
                                    | Some et ->
                                        List.filter (fun (ev : Masc_mcp.Trpg_engine_event.t) ->
                                          ev.event_type = et) events
                                  in
                                  List.iter (fun ev ->
                                    if not !closed then begin
                                      if not (send (trpg_event_to_sse ev)) then
                                        closed := true
                                      else
                                        last_seq := max !last_seq
                                          ev.Masc_mcp.Trpg_engine_event.seq
                                    end) events
                              | Error _ -> ());
                             incr keepalive_counter;
                             if !keepalive_counter >= polls_per_keepalive then begin
                               keepalive_counter := 0;
                               if not !closed then ignore (send ": keepalive\n\n")
                             end
                           end;
                           loop ()
                         end else
                           H2.Body.Writer.close writer
                       in
                       try loop () with exn ->
                         if not (is_cancelled exn) then
                           Printf.eprintf "[TRPG-SSE/H2] poll error for room %s: %s\n%!"
                             room_id_trimmed (Printexc.to_string exn))
                 | _ ->
                     ignore (send "event: error\ndata: {\"error\":\"server not ready\"}\n\n");
                     H2.Body.Writer.close writer)
          end

      | `POST, "/api/v1/trpg/actors/spawn" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match
              trpg_actor_spawn_json ~base_dir
                ~idempotency_key:
                  (get_header_any_case httpun_request.headers "idempotency-key")
                ~body_str
            with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~status:`Created ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `POST, "/api/v1/trpg/actors/claim" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_actor_claim_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~status:`Created ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `POST, "/api/v1/trpg/actors/release" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_actor_release_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `POST, "/api/v1/trpg/tts" ->
          h2_read_body h2_reqd (fun body_str ->
            match trpg_tts_proxy ~body_str with
            | Ok audio_bytes ->
                h2_respond_bytes ~content_type:"audio/mpeg"
                  ~extra_headers:cors h2_reqd audio_bytes
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
            | Error (_, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/council/debates" ->
          let state = get_server_state () in
          let base_path = state.Mcp_server.room_config.base_path in
          let json = council_debates_json httpun_request ~base_path in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/council/sessions" ->
          let json = council_sessions_json httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/board" ->
          let hearth = query_param httpun_request "hearth" in
          let sort_by = board_sort_order_of_request httpun_request in
          let exclude_system = bool_query_param httpun_request "exclude_system" ~default:false in
          let limit = int_query_param httpun_request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
          let offset = int_query_param httpun_request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
          let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
          let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
          let posts = filter_board_posts ~exclude_system posts in
          let karma_map = Board_dispatch.get_all_karma () in
          let get_karma author =
            try List.assoc author karma_map with Not_found -> 0
          in
          let paged = posts |> drop offset |> take limit in
          let posts_json = List.map (fun (p : Board.post) ->
            let author = Board.Agent_id.to_string p.author in
            board_post_dashboard_json ~author_karma:(get_karma author) p
          ) paged in
          let json = `Assoc [
            ("posts", `List posts_json);
            ("count", `Int (List.length posts_json));
            ("limit", `Int limit);
            ("offset", `Int offset);
            ("sort_by", `String (board_sort_label sort_by));
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/board/hearths" ->
          let hearths = Board_dispatch.list_hearths () in
          let json = `Assoc [
            ("hearths", `List (List.map (fun (name, count) ->
              `Assoc [("name", `String name); ("count", `Int count)]
            ) hearths));
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/board/flairs" ->
          let flairs = List.map Board.flair_to_yojson Board.available_flairs in
          let json = `Assoc [("flairs", `List flairs)] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, p
        when String.length p > 32
             && String.length p >= 24 + 8
             && String.sub p 0 24 = "/api/v1/council/debates/"
             && String.ends_with ~suffix:"/summary" p ->
          let prefix_len = 24 in
          let suffix_len = 8 in
          let debate_id_len = String.length p - prefix_len - suffix_len in
          if debate_id_len <= 0 then
            h2_respond_json h2_reqd {|{"error":"debate_id missing"}|}
              ~status:`Bad_request ~extra_headers:cors
          else
            let debate_id = String.sub p prefix_len debate_id_len in
            let state = get_server_state () in
            let base_path = state.Mcp_server.room_config.base_path in
            let (status, json) = council_debate_summary_json ~base_path ~debate_id in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json)
              ~status ~extra_headers:cors

      | `GET, p
        when String.length p > 33
             && String.length p >= 25 + 8
             && String.sub p 0 25 = "/api/v1/council/sessions/"
             && String.ends_with ~suffix:"/summary" p ->
          let prefix_len = 25 in
          let suffix_len = 8 in
          let session_id_len = String.length p - prefix_len - suffix_len in
          if session_id_len <= 0 then
            h2_respond_json h2_reqd {|{"error":"session_id missing"}|}
              ~status:`Bad_request ~extra_headers:cors
          else
            let session_id = String.sub p prefix_len session_id_len in
            let state = get_server_state () in
            let base_path = state.Mcp_server.room_config.base_path in
            let (status, json) = council_session_summary_json ~base_path ~session_id in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json)
              ~status ~extra_headers:cors

      | `GET, p when String.length p > 14 && String.sub p 0 14 = "/api/v1/board/" ->
          let post_id = String.sub p 14 (String.length p - 14) in
          let format = Option.value ~default:"nested" (query_param httpun_request "format") in
          let (status, body) = board_post_detail_json ~response_format:format ~post_id in
          h2_respond_json h2_reqd body ~status ~extra_headers:cors

      | `GET, "/api/v1/karma" ->
          let karma_list = Board_dispatch.get_all_karma () in
          let sorted = List.sort (fun (_, a) (_, b) -> compare b a) karma_list in
          let json = `Assoc [
            ("karma", `List (List.map (fun (agent, k) ->
              `Assoc [("agent", `String agent); ("karma", `Int k)]
            ) sorted));
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      (* ─────────────────────────────────────────────────────────────────────
         Static Assets
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/static/css/middleware.css" ->
          (match read_file (playground_asset_path "static/css/middleware.css") with
           | Ok body ->
               let headers = H2.Headers.of_list [
                 ("content-type", "text/css; charset=utf-8");
                 ("content-length", string_of_int (String.length body));
               ] in
               let response = H2.Response.create ~headers `OK in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.write_string writer body;
               H2.Body.Writer.close writer
           | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found)

      | `GET, "/static/js/middleware.js" ->
          (match read_file (playground_asset_path "static/js/middleware.js") with
           | Ok body ->
               let headers = H2.Headers.of_list [
                 ("content-type", "application/javascript; charset=utf-8");
                 ("content-length", string_of_int (String.length body));
               ] in
               let response = H2.Response.create ~headers `OK in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.write_string writer body;
               H2.Body.Writer.close writer
           | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found)

      (* Dashboard SPA: static assets *)
      | `GET, p when String.length p > 18
                   && String.sub p 0 18 = "/dashboard/assets/" ->
          let filename = String.sub p 18 (String.length p - 18) in
          if not (Masc_mcp.Web_dashboard.is_safe_asset_relative_path filename) then
            h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found
          else
            let file_path = Filename.concat (dashboard_asset_root ()) ("assets/" ^ filename) in
            (match read_file file_path with
             | Ok body ->
                 let ct = asset_content_type filename in
                 let headers = H2.Headers.of_list [
                   ("content-type", ct);
                   ("content-length", string_of_int (String.length body));
                   ("cache-control", "public, max-age=31536000, immutable");
                 ] in
                 let response = H2.Response.create ~headers `OK in
                 let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
                 H2.Body.Writer.write_string writer body;
                 H2.Body.Writer.close writer
             | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found)

      (* ─────────────────────────────────────────────────────────────────────
         Fallback
         ───────────────────────────────────────────────────────────────────── *)
      | _ ->
          h2_respond_text h2_reqd (Printf.sprintf "404 Not Found: %s" path) ~status:`Not_found ~extra_headers:cors

    in
    try
      if
        http_auth_strict_enabled ()
        && httpun_meth <> `OPTIONS
        && String.starts_with ~prefix:"/api/v1/trpg/" path
      then
        match authorize_read_request ~base_path httpun_request with
        | Ok () -> dispatch_h2_route ()
        | Error err ->
            let status = http_status_of_auth_error err in
            h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
      else
        dispatch_h2_route ()
    with exn ->
      let msg = Printexc.to_string exn in
      Printf.eprintf "[H2] Handler error: %s\n%!" msg;
      h2_respond_text h2_reqd ("500 Internal Server Error: " ^ msg) ~status:`Internal_server_error ~extra_headers:cors
  in
  let _ = request_handler in (* suppress warning - legacy httpun handler *)

  (* H2 error handler *)
  let _h2_error_handler _client_addr ?request:_ error respond =
    let msg = match error with
      | `Exn exn -> Printexc.to_string exn
      | `Bad_request -> "Bad request"
      | `Bad_gateway -> "Bad gateway"
      | `Internal_server_error -> "Internal server error"
    in
    let headers = H2.Headers.of_list [
      ("content-type", "text/plain");
      ("content-length", string_of_int (String.length msg));
    ] in
    let body = respond headers in
    H2.Body.Writer.write_string body msg;
    H2.Body.Writer.close body
  in

  (* HTTP/1.1 accept loop - Cloudflare Tunnel HTTP origin *)
  let rec accept_loop backoff_s =
    try
      let flow, client_addr = Eio.Net.accept ~sw socket in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Switch.run (fun conn_sw ->
          Eio.Switch.on_release conn_sw (fun () ->
            try Eio.Flow.close flow with _ -> ()
          );
          try
            (* HTTP/1.1 with httpun-eio - Cloudflare provides h2 to browser *)
            let conn_handler = Httpun_eio.Server.create_connection_handler
              ~sw:conn_sw
              ~request_handler:(fun client_addr -> request_handler client_addr)
              ~error_handler:(fun _client_addr ?request:_ error respond ->
                let msg = match error with
                  | `Exn exn -> Printexc.to_string exn
                  | `Bad_request -> "Bad request"
                  | `Bad_gateway -> "Bad gateway"
                  | `Internal_server_error -> "Internal server error"
                in
                let body = respond (Httpun.Headers.of_list [("content-type", "text/plain")]) in
                Httpun.Body.Writer.write_string body msg;
                Httpun.Body.Writer.close body)
            in
            conn_handler client_addr flow
          with exn ->
            Printf.eprintf "[HTTP] Connection error: %s\n%!" (Printexc.to_string exn)
        )
      );
      accept_loop 0.05
    with exn ->
      if is_cancelled exn then ()
      else begin
        Printf.eprintf "Accept error: %s\n%!" (Printexc.to_string exn);
        (try Eio.Time.sleep clock backoff_s with _ -> ());
        accept_loop (Float.min 2.0 (backoff_s *. 1.5))
      end
  in
  accept_loop 0.05

(** CLI options *)
let port =
  let doc = "Port to listen on" in
  Arg.(value & opt int 8935 & info ["p"; "port"] ~docv:"PORT" ~doc)

let base_path =
  let doc = "Base path for MASC data (.masc folder location)" in
  Arg.(value & opt string (default_base_path ()) & info ["base-path"] ~docv:"PATH" ~doc)

(** Graceful shutdown exception *)
exception Shutdown

let run_cmd port base_path =
  Eio_main.run @@ fun env ->
  (* Initialize Mirage_crypto RNG - MUST be inside Eio_main.run for thread-local state *)
  Mirage_crypto_rng_unix.use_default ();

  (* Enable Eio-aware locking in Prometheus metrics *)
  Masc_mcp.Prometheus.enable_eio ();
  Masc_mcp.Llm_response_cache.enable_eio ();

  (* Set global clock for Time_compat (Eio-native timestamps) *)
  Masc_mcp.Time_compat.set_clock (Eio.Stdenv.clock env);

  (* Initialize thread-safe token store for cancellation support *)
  Masc_mcp.Cancellation.TokenStore.init ();

  (* Graceful shutdown setup *)
  let switch_ref = ref None in
  let shutdown_initiated = ref false in
  let initiate_shutdown signal_name =
    if not !shutdown_initiated then begin
      shutdown_initiated := true;
      Printf.eprintf "\n🚀 MASC MCP: Received %s, shutting down gracefully...\n%!" signal_name;

      (* Broadcast shutdown notification to all SSE clients *)
      let shutdown_data = Printf.sprintf
        {|{"jsonrpc":"2.0","method":"notifications/shutdown","params":{"reason":"%s","message":"Server is shutting down, please reconnect"}}|}
        signal_name
      in
      Sse.broadcast (Yojson.Safe.from_string shutdown_data);
      Printf.eprintf "🚀 MASC MCP: Sent shutdown notification to %d SSE clients\n%!" (Sse.client_count ());

      (* Give clients 200ms to receive the notification *)
      Unix.sleepf 0.2;

      (* Run all shutdown hooks (cancel orchestrator, close SSE, etc.) *)
      Masc_mcp.Shutdown_hooks.run_all ();

      (* Flush dirty board data to prevent data loss *)
      (try Board_dispatch.flush ()
       with _ -> Printf.eprintf "[Shutdown] Board flush skipped (not initialized)\n%!");

      (* Also close local SSE connections tracked in main_eio *)
      close_all_sse_connections ();

      (* Give connections 200ms to complete close handshake *)
      Unix.sleepf 0.2;

      match !switch_ref with
      | Some sw -> Eio.Switch.fail sw Shutdown
      | None -> ()
    end
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGTERM"));
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGINT"));

  let max_bind_retries = 5 in
  let rec try_start attempt =
    (try
      Eio.Switch.run @@ fun sw ->
      switch_ref := Some sw;
      run_server ~sw ~env ~port ~base_path
    with
    | Shutdown ->
        Printf.eprintf "🚀 MASC MCP: Shutdown complete.\n%!"
    | Eio.Cancel.Cancelled _ ->
        Printf.eprintf "🚀 MASC MCP: Shutdown complete.\n%!"
    | Unix.Unix_error (Unix.EADDRINUSE, _, _) when attempt < max_bind_retries ->
        let delay = Float.min 30.0 (2.0 ** Float.of_int attempt) in
        Printf.eprintf "⚠️  Port %d in use, retrying in %.0fs (attempt %d/%d)...\n%!"
          port delay (attempt + 1) max_bind_retries;
        Time_compat.sleep delay;
        try_start (attempt + 1)
    | Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
        Printf.eprintf "❌ [MASC FATAL] Port %d is still in use after %d retries.\n%!"
          port max_bind_retries;
        Printf.eprintf "   Try: lsof -i :%d | grep LISTEN\n%!" port;
        exit 1
    | Unix.Unix_error (Unix.EACCES, _, _) ->
        Printf.eprintf "❌ [MASC FATAL] Permission denied binding to port %d.\n%!" port;
        exit 1)
  in
  try_start 0

let cmd =
  let doc = "MASC MCP Server" in
  let info = Cmd.info "masc-mcp" ~version:Masc_mcp.Version.version ~doc in
  Cmd.v info Term.(const run_cmd $ port $ base_path)

let () = exit (Cmd.eval cmd)
