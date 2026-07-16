(** Server_dashboard_http — Dashboard HTTP handlers (facade). *)

include Server_dashboard_http_core
include Server_dashboard_http_runtime_info
include Server_dashboard_http_execution_surfaces
include Server_dashboard_http_namespace_truth
open Masc_domain
open Server_utils

let dashboard_projection_cache_ttl_s =
  Server_dashboard_http_core_cache.dashboard_projection_cache_ttl_s
;;

(* Repository observation snapshot handler *)
let handle_repository_observation_snapshot ~sw:_ ~clock request reqd =
  Server_auth.with_public_read (fun state req inner_reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match Repo_store.load_all ~base_path with
    | Error error ->
      Http_server_eio.Response.json_value
        ~status:`Internal_server_error
        ~compress:true
        ~request:req
        (`Assoc [ "ok", `Bool false; "error", `String error ])
        inner_reqd
    | Ok repos ->
      let repo_list =
        List.map
          (Server_routes_http_routes_repositories.repository_json ~base_path)
          repos
      in
      let snapshot =
        `Assoc
          [ "ok", `Bool true
          ; "timestamp", `Float (Eio.Time.now clock)
          ; "repository_count", `Int (List.length repos)
          ; "repositories", `List repo_list
          ]
      in
      Http_server_eio.Response.json_value
        ~compress:true
        ~request:req
        snapshot
        inner_reqd)
    request reqd

(* Wire task mutation hook: invalidate execution cache on any task
   add/transition so the dashboard serves fresh backlog data. *)
let () = Atomic.set Workspace_hooks.on_task_mutation_fn invalidate_execution_cache

let dashboard_namespace_truth_focus_json =
  Server_dashboard_http_namespace_truth_support.dashboard_namespace_truth_focus_json
;;

let dashboard_namespace_truth_http_json =
  Server_dashboard_http_namespace_truth.dashboard_namespace_truth_http_json
;;

let dashboard_board_json
      ?config
      ?hearth
      ?author_filter
      ?(sort_by = Board_dispatch.Hot)
      ?(exclude_system = false)
      ?(exclude_automation = false)
      ?(limit = 100)
      ?(offset = 0)
      ?voter
      ?(blind_votes = false)
      ()
  : Yojson.Safe.t
  =
  let limit = clamp ~min_v:1 ~max_v:500 limit in
  let offset = clamp ~min_v:0 ~max_v:5000 offset in
  let author_filter = Option.map board_actor_author_for_write author_filter in
  let config_key =
    match config with
    | None -> "-"
    | Some config -> config.Workspace.base_path
  in
  let cache_key =
    Printf.sprintf
      "board:memory:%s;%s;%s;%b;%b;%d;%d;%s;%s;%b"
      (Option.value ~default:"-" hearth)
      (Option.value ~default:"-" author_filter)
      (board_sort_label sort_by)
      exclude_system
      exclude_automation
      limit
      offset
      config_key
      (Option.value ~default:"-" voter)
      blind_votes
  in
  Dashboard_cache.get_or_compute cache_key ~ttl:dashboard_projection_cache_ttl_s (fun () ->
    (* /api/v1/dashboard/board was measured at 30-44s on hot keeper
       fleets.  The compute below scans the post store, fetches the
       karma map, and per-post enriches with vote + contributor
       quality.  Running this on the Eio main domain blocked every
       other HTTP fiber for the duration.  Domain_pool_ref offloads
       to a worker domain; the [Dashboard_cache] above keeps user
       requests on the cache fast-path so they never wait for this
       refresh. *)
    Domain_pool_ref.submit_io_or_inline (fun () ->
      let base_fetch =
        board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset
      in
      (* Fetch one extra beyond the requested page so we can answer has_more
         without a second query. total is only emitted when the result fits
         entirely inside the fetched window — otherwise null (unknown). *)
      let probe_fetch = base_fetch + 1 in
      let posts =
        Board_dispatch.list_posts
          ?hearth
          ~sort_by
          ~exclude_system
          ~exclude_automation
          ?author_filter
          ~limit:probe_fetch
          ()
      in
      let karma_map = Board_dispatch.get_all_karma () in
      let get_karma author = Option.value ~default:0 (List.assoc_opt author karma_map) in
      let fetched_len = List.length posts in
      let window_end = offset + limit in
      let has_more = fetched_len > window_end in
      let total_json : Yojson.Safe.t = if has_more then `Null else `Int fetched_len in
      let paged = posts |> drop offset |> take limit in
      let contributor_quality_for = board_contributor_quality_lookup ?config () in
      let posts_json =
        List.map
          (fun (post : Board.post) ->
             let author = Board.Agent_id.to_string post.author in
             let post_id = Board.Post_id.to_string post.id in
             let current_vote = board_current_vote_for_post ~voter ~post_id in
             let contributor_quality = contributor_quality_for author in
             board_post_dashboard_json
               ~blind_votes
               ?current_vote
               ?contributor_quality
               ~author_karma:(get_karma author)
               post)
          paged
      in
      `Assoc
        [ "generated_at", `String (Masc_domain.now_iso ())
        ; ( "summary"
          , `Assoc
              [ "visible_posts", `Int (List.length posts_json)
              ; "sort_by", `String (board_sort_label sort_by)
              ; "exclude_system", `Bool exclude_system
              ; "exclude_automation", `Bool exclude_automation
              ] )
        ; "posts", `List posts_json
        ; "count", `Int (List.length posts_json)
        ; "limit", `Int limit
        ; "offset", `Int offset
        ; "has_more", `Bool has_more
        ; "total", total_json
        ; "sort_by", `String (board_sort_label sort_by)
        ]))
;;

let dashboard_memory_http_json ?config request : Yojson.Safe.t =
  let hearth = query_param request "hearth" in
  let author_filter =
    query_param request "author"
    |> Option.map String.trim
    |> Fun.flip Option.bind (fun s ->
      if s = "" then None else Some (board_actor_author_for_write s))
  in
  let sort_by = board_sort_order_of_request request in
  let exclude_system = bool_query_param request "exclude_system" ~default:false in
  let exclude_automation = bool_query_param request "exclude_automation" ~default:false in
  let limit = int_query_param request "limit" ~default:100 |> clamp ~min_v:1 ~max_v:500 in
  let offset =
    int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000
  in
  let voter = board_voter_query request in
  let blind_votes = bool_query_param request "blind_votes" ~default:false in
  dashboard_board_json
    ?config
    ?hearth
    ?author_filter
    ~sort_by
    ~exclude_system
    ~exclude_automation
    ~limit
    ~offset
    ?voter
    ~blind_votes
    ()
;;

include Server_dashboard_http_memory_subsystems

let dashboard_gate_http_json request ~base_path : Yojson.Safe.t =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset =
    int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000
  in
  let status_filter = None in
  let force = bool_query_param request "force" ~default:false in
  let cache_key =
    Printf.sprintf "gate:%s;%d;%d" base_path limit offset
  in
  let compute () =
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Dashboard_gate.dashboard_json ~base_path ~limit ~offset ~status_filter)
  in
  if force then Dashboard_cache.invalidate cache_key;
  Dashboard_cache.get_or_compute cache_key ~ttl:dashboard_projection_cache_ttl_s compute
;;

(** Read the optional [?window=<minutes>] query param.
    Defaults to 60 minutes; clamped to [5..1440]. *)
let dashboard_gate_tool_events_http_json request : Yojson.Safe.t =
  let window =
    int_query_param request "window" ~default:60 |> clamp ~min_v:5 ~max_v:1440
  in
  Dashboard_gate_metrics.gate_tool_events_json ~window_minutes:window ()
;;

(* /api/v1/dashboard/proof was measured at 28-60s (timeout) under
   live load.  The compute calls [Dashboard_verification.summary_json]
   and [Dashboard_verification.requests_json] back-to-back; each
   walks the on-disk verification request store, so the work runs
   inline on the Eio main domain and starves other HTTP fibers.

   Same fix pattern as PR #18991 / #18993 / #18994: wrap in
   [Dashboard_cache.get_or_compute] for stale-while-revalidate and
   push the compute through [Domain_pool_ref.submit_io_or_inline]
   so the main domain keeps serving requests during refresh. *)
let dashboard_proof_compute ~config ~limit ~recent () : Yojson.Safe.t =
  let base_path = config.Workspace.base_path in
  (* Single disk scan via [proof_compose]; the historical
     [summary_json] + [requests_json] sequence walked the verification
     store twice per refresh. *)
  let verification_summary, verification_requests =
    Dashboard_verification.proof_compose ~base_path ~recent ~limit ()
  in
  let proof_source ~id ~label ~route =
    `Assoc [ "id", `String id; "label", `String label; "route", `String route ]
  in
  let proof_sources =
    [
      proof_source ~id:"verification_summary"
        ~label:"Verification status buckets"
        ~route:"/api/v1/verification/summary";
      proof_source ~id:"verification_requests"
        ~label:"Verification request evidence"
        ~route:"/api/v1/verification/requests";
      proof_source ~id:"tlc_results"
        ~label:"TLA+ verification logs"
        ~route:"/api/v1/verification/tlc-results";
      proof_source ~id:"keeper_feature_proof"
        ~label:"Keeper autonomy feature proof"
        ~route:"/api/v1/dashboard/keeper-feature-proof";
      proof_source ~id:"execution_trust"
        ~label:"Execution trust provenance"
        ~route:"/api/v1/dashboard/execution-trust";
    ]
  in
  let by_status =
    match verification_summary with
    | `Assoc fields -> (
        match List.assoc_opt "by_status" fields with
        | Some (`Assoc status_fields) -> status_fields
        | _ -> [])
    | _ -> []
  in
  let status_int key =
    match List.assoc_opt key by_status with
    | Some (`Int n) -> n
    | _ -> 0
  in
  `Assoc
    [
      "generated_at", `String (Masc_domain.now_iso ());
      ( "summary",
        `Assoc
          [
            "verification_total",
            (match verification_summary with
             | `Assoc fields -> (
                 match List.assoc_opt "total" fields with
                 | Some (`Int n) -> `Int n
                 | _ -> `Int 0)
             | _ -> `Int 0);
            "verification_pending", `Int (status_int "pending");
            "verification_rejected", `Int (status_int "rejected");
            "proof_source_count", `Int (List.length proof_sources);
          ] );
      ( "verification",
        `Assoc
          [
            "summary", verification_summary;
            "requests", verification_requests;
          ] );
      "proof_sources", `List proof_sources;
    ]
;;

let dashboard_proof_http_json ~config request : Yojson.Safe.t =
  let limit = int_query_param request "limit" ~default:25 |> clamp ~min_v:1 ~max_v:100 in
  let recent =
    int_query_param request "recent" ~default:5 |> clamp ~min_v:0 ~max_v:20
  in
  let key =
    Printf.sprintf "dashboard.proof:%s;%d;%d" config.Workspace.base_path limit recent
  in
  Dashboard_cache.get_or_compute key ~ttl:dashboard_projection_cache_ttl_s (fun () ->
    Domain_pool_ref.submit_io_or_inline (fun () ->
      dashboard_proof_compute ~config ~limit ~recent ()))
;;

type approval_resolve_http_error =
  | Bad_request of string
  | Gone of Keeper_approval_queue.resolve_error
  | Unavailable of Keeper_approval_queue.resolve_error

let approval_resolve_decision_field = "decision"
let approval_resolve_reason_field = "reason"
let approval_resolve_approve_name = "approve"
let approval_resolve_reject_name = "reject"
let approval_resolve_decision_required_message = "decision is required"
let approval_resolve_decision_invalid_message = "decision must be 'approve' or 'reject'"
let approval_resolve_default_reject_reason = "dashboard rejected approval"

type approval_resolve_decision =
  | Approval_resolve_approve
  | Approval_resolve_reject of string

let approval_resolve_decision_name = function
  | Approval_resolve_approve -> approval_resolve_approve_name
  | Approval_resolve_reject _ -> approval_resolve_reject_name
;;

let approval_resolve_decision_to_queue_decision = function
  | Approval_resolve_approve -> Keeper_approval_queue.Decision.Approve
  | Approval_resolve_reject reason -> Keeper_approval_queue.Decision.Reject reason
;;

let approval_resolve_decision_of_json args =
  match Safe_ops.json_string_opt approval_resolve_decision_field args with
  | None -> Error (Bad_request approval_resolve_decision_required_message)
  | Some raw ->
    (match raw |> String.trim |> String.lowercase_ascii with
     | name when String.equal name approval_resolve_approve_name ->
       Ok Approval_resolve_approve
     | name when String.equal name approval_resolve_reject_name ->
       let reason =
         Safe_ops.json_string_opt approval_resolve_reason_field args
         |> Option.value ~default:approval_resolve_default_reject_reason
       in
       Ok (Approval_resolve_reject reason)
     | _ -> Error (Bad_request approval_resolve_decision_invalid_message))
;;

let approval_resolve_http_error_to_string = function
  | Bad_request msg -> msg
  | Gone err -> Keeper_approval_queue.resolve_error_to_string err
  | Unavailable err -> Keeper_approval_queue.resolve_error_to_string err
;;

let dashboard_gate_resolve_http_json ~created_by ~(args : Yojson.Safe.t)
  : (Yojson.Safe.t, approval_resolve_http_error) result
  =
  match Safe_ops.json_string_opt "id" args with
  | None -> Error (Bad_request "id is required")
  | Some id ->
    let remember_rule =
      Safe_ops.json_bool_opt "remember_rule" args |> Option.value ~default:false
    in
    (* RFC-0305: a missing [decision] field must not default to approve — this
       resolves a pending HITL approval, so an omitted/malformed decision is a
       bad request, not a silent grant. Mirrors the [id]-required check above. *)
    (* Carry the canonical name alongside the decision so the success response
       echoes what was applied without re-matching [approval_decision] (whose
       [Edit] arm is never produced here). *)
    (match approval_resolve_decision_of_json args with
     | Error _ as err -> err
     | Ok decision ->
       let decision_name = approval_resolve_decision_name decision in
       let decision = approval_resolve_decision_to_queue_decision decision in
       (match
          Keeper_approval_queue.resolve_with_policy
            ~id
            ~decision
            ~remember_rule
            ~created_by
            ()
        with
        | Ok result ->
          Ok
            (`Assoc
                [ "ok", `Bool true
                ; "id", `String id
                ; "decision", `String decision_name
                ; ( "rule_id"
                  , match result.remembered_rule with
                    | Some rule -> `String rule.id
                    | None -> `Null )
                ])
        | Error (Keeper_approval_queue.Delivery_failed _ as err) ->
          Error (Unavailable err)
        | Error (Keeper_approval_queue.Persistence_failed _ as err) ->
          Error (Unavailable err)
        | Error
            (( Keeper_approval_queue.Not_found _
             | Keeper_approval_queue.Already_resolved _ ) as err) ->
          Error (Gone err)))
;;

let dashboard_gate_retry_http_json ~requested_by ~(args : Yojson.Safe.t) =
  match Safe_ops.json_string_opt "id" args with
  | None -> Error "id is required"
  | Some id ->
    (match Keeper_gate.retry_failed_auto_judge ~requested_by id with
     | Error _ as error -> error
     | Ok () -> Ok (`Assoc [ "ok", `Bool true; "id", `String id ]))
;;

let dashboard_gate_rule_delete_http_json ~base_path ~(args : Yojson.Safe.t)
  : (Yojson.Safe.t, string) result
  =
  match Safe_ops.json_string_opt "id" args with
  | None -> Error "id is required"
  | Some id ->
    (match Keeper_approval_queue.delete_rule ~base_path ~id () with
     | Ok deleted ->
         Keeper_approval_queue.audit_rule_event
           ~base_path
           ~event_type:"rule_deleted"
           deleted;
         Ok (`Assoc [ "ok", `Bool true; "id", `String deleted.id ])
       | Error error ->
         Error (Keeper_approval_queue.rule_store_error_to_string error))
;;

let dashboard_schedule_prune_http_json
      ~config
      ~operator_name
  : (Yojson.Safe.t, string) result
  =
  Server_dashboard_http_schedule_actions.prune_http_json
    ~config
    ~operator_name
;;

(* Dashboard-initiated verification verdict. Mirrors the tool_task path for
   Approve_verification / Reject_verification: persist the Verification store
   verdict before the task FSM transition, then publish Board + SSE
   notifications only after the transition succeeds.

   [verifier] is a namespaced agent_id of the form "operator:<actor>".
   The colon form is permitted by Validation.Agent_id and keeps operator
   verdicts distinguishable from peer-agent verdicts in attribution.

   Decisions are strictly approve | reject — unknown values return
   Bad_request rather than defaulting, per Det/NonDet boundary. *)
let dashboard_verification_resolve_http_json
      ~(config : Workspace.config)
      ~(verifier : string)
      ~(args : Yojson.Safe.t)
  : (Yojson.Safe.t, string) result
  =
  let open Result in
  let ( let* ) = bind in
  let* task_id =
    match Safe_ops.json_string_opt "task_id" args with
    | Some s ->
      let trimmed = String.trim s in
      if trimmed <> "" then Ok trimmed else Error "task_id is required"
    | None -> Error "task_id is required"
  in
  let* verification_id =
    match Safe_ops.json_string_opt "verification_id" args with
    | Some s ->
      let trimmed = String.trim s in
      if trimmed <> "" then Ok trimmed else Error "verification_id is required"
    | None -> Error "verification_id is required"
  in
  let decision_name =
    Safe_ops.json_string_opt "decision" args
    |> Option.value ~default:""
    |> String.trim
    |> String.lowercase_ascii
  in
  let reason = Safe_ops.json_string_opt "reason" args |> Option.value ~default:"" in
  let* action =
    match decision_name with
    | "approve" -> Ok Masc_domain.Approve_verification
    | "reject" -> Ok Masc_domain.Reject_verification
    | "" -> Error "decision is required (approve | reject)"
    | other ->
      Error (Printf.sprintf "decision must be 'approve' or 'reject' (got %s)" other)
  in
  let* task =
    Workspace.get_tasks_raw config
    |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
    |> function
    | None -> Error (Printf.sprintf "task %s not found" task_id)
    | Some task -> Ok task
  in
  let* () =
    match task.task_status with
    | Masc_domain.AwaitingVerification { verification_id = state_id; _ }
      when String.equal state_id verification_id -> Ok ()
    | Masc_domain.AwaitingVerification { verification_id = state_id; _ } ->
      Error
        (Printf.sprintf
           "verification_id mismatch for task %s: request=%s state=%s"
           task_id
           verification_id
           state_id)
    | status ->
      Error
        (Printf.sprintf
           "task %s is %s, not awaiting verification"
           task_id
           (Masc_domain.task_status_to_string status))
  in
  let handoff_context =
    match task.handoff_context with
    | Some handoff -> Masc_domain.task_handoff_context_to_yojson handoff
    | None ->
      `Assoc
        [ "summary", `String reason
        ; "evidence_refs", `List []
        ]
  in
  let transition_args =
    `Assoc
      [ "task_id", `String task_id
      ; "action", `String (Masc_domain.task_action_to_string action)
      ; "notes", `String reason
      ; "reason", `String reason
      ; "handoff_context", handoff_context
      ]
  in
  let task_context : Task.Tool.context =
    { config; agent_name = verifier; sw = None }
  in
  match Task.Tool.dispatch task_context ~name:"masc_transition" ~args:transition_args with
  | None -> Error "Task transition handler is unavailable"
  | Some result when not (Tool_result.is_success result) ->
    Error (Tool_result.message result)
  | Some result ->
    Ok
      (`Assoc
         [ "ok", `Bool true
         ; "task_id", `String task_id
         ; "verification_id", `String verification_id
         ; "decision", `String decision_name
         ; "verifier", `String verifier
         ; "result", Tool_result.data result
         ])
;;

let dashboard_planning_http_json ~(config : Workspace.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let rollup = Goal_store.compute_rollup goals in
  let task_rollup =
    dashboard_tasks_safe config
    |> List.fold_left
         (fun (todo, claimed, running, done_count, cancelled) (task : Masc_domain.task) ->
            match task.task_status with
            | Todo -> todo + 1, claimed, running, done_count, cancelled
            | Claimed _ -> todo, claimed + 1, running, done_count, cancelled
            | InProgress _ | AwaitingVerification _ ->
              todo, claimed, running + 1, done_count, cancelled
            | Done _ -> todo, claimed, running, done_count + 1, cancelled
            | Cancelled _ -> todo, claimed, running, done_count, cancelled + 1)
         (0, 0, 0, 0, 0)
  in
  let todo_count, claimed_count, running_count, done_count, cancelled_count =
    task_rollup
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; "goals", `List (List.map Goal_store.goal_to_yojson goals)
    ; "rollup", Goal_store.rollup_to_yojson rollup
    ; ( "task_backlog"
      , `Assoc
          [ "todo", `Int todo_count
          ; "claimed", `Int claimed_count
          ; "in_progress", `Int running_count
          ; "done", `Int done_count
          ; "cancelled", `Int cancelled_count
          ] )
    ]
;;

let dashboard_goals_tree_http_json ~(config : Workspace.config) : Yojson.Safe.t =
  Dashboard_goals.dashboard_goals_tree_json ~config
;;

let dashboard_goals_snapshot_json ~(config : Workspace.config) : Yojson.Safe.t =
  (* RFC-0284: carry the goal-loop OODA status alongside planning/tree so the
     WS "goals" slice's initial snapshot (and the /goals HTTP pull) paint the
     goal-loop panel without a separate fetch. Live updates arrive via the
     [goal_loop_status] delta (Server_dashboard_http_goal_loop_broadcast). *)
  `Assoc
    [ "planning", dashboard_planning_http_json ~config
    ; "tree", dashboard_goals_tree_http_json ~config
    ; "loop", Dashboard_goal_loop.status_json ~base_path:config.base_path ()
    ]

let dashboard_ide_snapshot_json ~(config : Workspace.config) : Yojson.Safe.t =
  let base_path = config.base_path in
  let partition = Ide_paths.Legacy_default in
  let limit = 10 in
  let events =
    Ide_bridge.list_events
      ~base_path
      ~partition
      ~limit
      ~offset:0
      ()
  in
  let cursors =
    Ide_bridge.list_cursors
      ~base_path
      ~partition
      ~limit
      ~offset:0
      ()
  in
  let annotations =
    Ide_annotations.list
      ~base_dir:base_path
      ~partition
      ~filter:{ file_path = None; keeper_id = None; goal_id = None; task_id = None }
      ()
  in
  let regions =
    Ide_region_tracker.read_regions
      ~base_dir:base_path
      ~partition
      ()
  in
  let active_keepers =
    try
      List.map
        (fun (a : Client_identity.t) ->
           `Assoc
             [ "keeper_id", `String a.Client_identity.agent_name
             ; "last_seen_ms", `Intlit (Printf.sprintf "%.0f" (a.Client_identity.registered_at *. 1000.0))
             ])
        (Client_registry_eio.list_active ~within_seconds:300.0 ())
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _exn -> []
  in
  let events_count = List.length events in
  let cursors_count = List.length cursors in
  let annotations_count = List.length annotations in
  let regions_count = List.length regions in
  let active_keepers_count = List.length active_keepers in
  `Assoc
    [ "partition_kind", `String (Ide_paths.partition_kind partition)
    ; "partition_orphan", `Bool (Ide_paths.partition_is_orphan partition)
    ; "events_count", `Int events_count
    ; "cursors_count", `Int cursors_count
    ; "annotations_count", `Int annotations_count
    ; "regions_count", `Int regions_count
    ; "active_keepers_count", `Int active_keepers_count
    ; "events", `Assoc
        [ "count", `Int events_count
        ; "recent", `List events
        ]
    ; "cursors", `Assoc
        [ "count", `Int cursors_count
        ; "recent", `List cursors
        ]
    ; "annotations", `Assoc
        [ "count", `Int annotations_count
        ]
    ; "regions", `Assoc
        [ "count", `Int regions_count
        ]
    ; "presence", `Assoc
        [ "active_keepers", `List active_keepers
        ; "count", `Int active_keepers_count
        ]
    ; "freshness", `Assoc
        [ "snapshot_at", `String (Masc_domain.now_iso ())
        ]
    ]
;;
;;


(* Composite fleet snapshot / runtime attention / recommended-actions
   extracted to [Server_dashboard_http_composite] (godfile decomp). *)
include Server_dashboard_http_composite

let dashboard_goal_detail_http_json ~(config : Workspace.config) ~goal_id : Yojson.Safe.t =
  match Dashboard_goals.goal_detail_json ~config ~goal_id with
  | Ok json -> json
  | Error message ->
    `Assoc [ "ok", `Bool false; "error", `String message; "goal_id", `String goal_id ]
;;

let explicit_operator_actor ~authorized_actor request =
  match
    Server_auth.auth_token_from_request request,
    Server_auth.request_actor_hint request
  with
  | None, None -> Error "operator request actor is required"
  | None, Some _
  | Some _, None
  | Some _, Some _ -> Ok authorized_actor
;;

let operator_control_context ~state ~sw ~clock ~config ~agent_name
    : _ Operator_control.context
  =
  { config
  ; agent_name
  ; sw
  ; clock
  ; proc_mgr = state.Mcp_server.proc_mgr
  ; net = state.Mcp_server.net
  ; delegated_dispatch =
      Some
        (Keeper_tool_boundary.delegated_dispatch
           ~config
           ~agent_name
           ~sw
           ~clock
           ~proc_mgr:state.Mcp_server.proc_mgr
           ~net:state.Mcp_server.net
           ~publication_recovery_provider:
             (Mcp_server.publication_recovery_availability_provider state))
  ; mcp_session_id = None
  }
;;

let operator_action_http_json ~state ~sw ~clock ~authorized_actor request ~args =
  let workspace_scope = Mcp_server.workspace_scope state in
  match explicit_operator_actor ~authorized_actor request with
  | Error _ as error -> error
  | Ok actor ->
    let ctx =
      operator_control_context
        ~state
        ~sw
        ~clock
        ~config:workspace_scope.config
        ~agent_name:actor
    in
    Operator_control.action_json ~actor_hint:actor ctx args
;;

let operator_confirm_http_json ~state ~sw ~clock ~authorized_actor request ~args =
  let workspace_scope = Mcp_server.workspace_scope state in
  match explicit_operator_actor ~authorized_actor request with
  | Error _ as error -> error
  | Ok actor ->
    let ctx =
      operator_control_context
        ~state
        ~sw
        ~clock
        ~config:workspace_scope.config
        ~agent_name:actor
    in
    Operator_control.confirm_json ~actor_hint:actor ctx args
;;

let operator_error_json message =
  Tool_args.error_assoc [ "message", `String message ]
;;

(* Cold-start bootstrap aggregator.

   Bundles the snapshot of multiple dashboard slices into a single JSON
   payload so the frontend does not fan out into N parallel HTTP calls
   under Executor_pool contention.  Each slice is computed sequentially
   because every SSOT helper already chooses inline-shared vs
   offloaded-readonly internally; parallel fan-out via [Eio.Fiber.all]
   is a milestone-2 follow-up only if measurement shows latency
   dominates.

   Per-slice exceptions are captured here rather than 500-ing the whole
   bootstrap.  The client payload deliberately uses the stable shape
   {"error":"slice_unavailable","slice":"<name>"} so a public-read
   client never sees raw [Printexc.to_string] output (path leakage,
   stack-derived strings).  The full exception text still goes to the
   server warn log for ops debugging.

   The full goals tree is intentionally omitted from this startup payload:
   [/api/v1/dashboard/goals] owns that heavier route-specific read.  The
   overview already gets the flat planning goals here, and planning/work
   routes call [refreshGoals] when they need the tree.

   Both the HTTP/1.1 router (server_routes_http_routes_dashboard) and
   the HTTP/2 gateway (server_h2_gateway) call this single SSOT so the
   payload shape, slice list, and error contract cannot drift between
   transports. *)
let dashboard_bootstrap_http_json
      ~(state : Mcp_server.server_state)
      ~sw
      ~(clock : _ Eio.Time.clock_ty Eio.Resource.t)
      (request : Httpun.Request.t)
  : Yojson.Safe.t
  =
  let slice name f =
    try name, f () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.warn
        "[dashboard-bootstrap] slice %s failed: %s"
        name
        (Printexc.to_string exn);
      name, `Assoc [ "error", `String "slice_unavailable"; "slice", `String name ]
  in
  let shell =
    slice "shell" (fun () ->
      dashboard_shell_http_json
        ?clock:state.Mcp_server.clock
        ~request
        ~light:true
        (Mcp_server.workspace_config state))
  in
  let execution =
    slice "execution" (fun () -> dashboard_execution_http_json ~state ~sw ~clock request)
  in
  let planning =
    (* Share the standalone /api/v1/dashboard/planning cache (same key + ttl) so
       a page that loads bootstrap and the planning panel computes the planning
       slice once. Previously bootstrap called the compute path directly,
       bypassing Dashboard_cache and re-reading goals/backlog on every load. *)
    slice "planning" (fun () ->
      let cache_key =
        Printf.sprintf "planning:%s" (Mcp_server.workspace_config state).base_path
      in
      Dashboard_cache.get_or_compute cache_key
        ~ttl:Server_dashboard_http_core_cache.standard_cache_ttl_s (fun () ->
          Domain_pool_ref.submit_io_or_inline (fun () ->
            dashboard_planning_http_json ~config:(Mcp_server.workspace_config state))))
  in
  let namespace_truth =
    slice "namespace_truth" (fun () ->
      (* RFC-0138 Phase 3 Step 3 follow-up — route through the snapshot
         selector instead of calling the compute path directly so the
         lock-free read takes effect for /api/v1/dashboard/bootstrap as
         well as /project-snapshot.  Without this wire, the
         "fallback runs ≤1× per process" claim in #16738 is false for
         bootstrap-driven loads. *)
      Server_dashboard_snapshot_select.select_project_snapshot_json
        ~state ~sw ~clock request)
  in
  let goal_loop_status =
    slice "goal_loop_status" (fun () ->
      Dashboard_goal_loop.status_json ~base_path:(Mcp_server.workspace_config state).base_path ())
  in
  `Assoc
    [ "served_at", `String (Masc_domain.now_iso ())
    ; "milestone", `Int 1
    ; shell
    ; execution
    ; planning
    ; namespace_truth
    ; goal_loop_status
    ]
;;
