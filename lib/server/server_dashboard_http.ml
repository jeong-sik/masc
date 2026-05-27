(** Server_dashboard_http — Dashboard HTTP handlers (facade). *)

include Server_dashboard_http_core
include Server_dashboard_http_runtime_info
include Server_dashboard_http_execution_surfaces
include Server_dashboard_http_namespace_truth
open Masc_domain
open Server_utils

(* Wire task mutation hook: invalidate execution cache on any task
   add/transition so the dashboard serves fresh backlog data. *)
let () = Atomic.set Coord_hooks.on_task_mutation_fn invalidate_execution_cache

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
    | Some config -> config.Coord.base_path
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
  Dashboard_cache.get_or_compute cache_key ~ttl:10.0 (fun () ->
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

let dashboard_governance_http_json request ~base_path : Yojson.Safe.t =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset =
    int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000
  in
  let status_filter = None in
  Dashboard_governance.dashboard_json ~base_path ~limit ~offset ~status_filter
;;

(** Read the optional [?window=<minutes>] query param.
    Defaults to 60 minutes; clamped to [5..1440]. *)
let dashboard_governance_tool_events_http_json request : Yojson.Safe.t =
  let window =
    int_query_param request "window" ~default:60 |> clamp ~min_v:5 ~max_v:1440
  in
  Dashboard_governance_metrics.governance_tool_events_json ~window_minutes:window ()
;;

let dashboard_proof_http_json ~config request : Yojson.Safe.t =
  let limit = int_query_param request "limit" ~default:25 |> clamp ~min_v:1 ~max_v:100 in
  let recent =
    int_query_param request "recent" ~default:5 |> clamp ~min_v:0 ~max_v:20
  in
  let base_path = config.Coord.base_path in
  let verification_summary =
    Dashboard_verification.summary_json ~base_path ~recent ()
  in
  let verification_requests =
    Dashboard_verification.requests_json ~base_path ~limit ()
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
      proof_source ~id:"surface_readiness"
        ~label:"Dashboard surface readiness refs"
        ~route:"/api/v1/dashboard/surface-readiness";
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

type approval_resolve_http_error =
  | Bad_request of string
  | Gone of Keeper_approval_queue.resolve_error

let approval_resolve_http_error_to_string = function
  | Bad_request msg -> msg
  | Gone err -> Keeper_approval_queue.resolve_error_to_string err
;;

let dashboard_governance_approval_resolve_http_json ~base_path ~(args : Yojson.Safe.t)
  : (Yojson.Safe.t, approval_resolve_http_error) result
  =
  match Safe_ops.json_string_opt "id" args with
  | None -> Error (Bad_request "id is required")
  | Some id ->
    let remember_rule =
      Safe_ops.json_bool_opt "remember_rule" args |> Option.value ~default:false
    in
    let decision_name =
      Safe_ops.json_string_opt "decision" args
      |> Option.value ~default:"approve"
      |> String.trim
      |> String.lowercase_ascii
    in
    let decision =
      match decision_name with
      | "approve" -> Ok Agent_sdk.Hooks.Approve
      | "reject" ->
        let reason =
          Safe_ops.json_string_opt "reason" args
          |> Option.value ~default:"dashboard rejected approval"
        in
        Ok (Agent_sdk.Hooks.Reject reason)
      | _ -> Error (Bad_request "decision must be 'approve' or 'reject'")
    in
    (match decision with
     | Error _ as err -> err
     | Ok decision ->
       (match
          Keeper_approval_queue.resolve_with_policy
            ~id
            ~decision
            ~base_path
            ~remember_rule
            ~created_by:"dashboard"
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
        | Error err -> Error (Gone err)))
;;

let dashboard_governance_approval_rule_delete_http_json ~base_path ~(args : Yojson.Safe.t)
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
     | Error message -> Error message)
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
      ~(config : Coord.config)
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
  let prepare_verification_verdict ~task:_ ~verifier ~verification_id:state_vid ~decision =
    if state_vid <> verification_id
    then
      Error
        (Printf.sprintf
           "verification_id mismatch for task %s: request=%s state=%s"
           task_id
           verification_id
           state_vid)
    else (
      match decision with
      | `Approve notes ->
        Verification_protocol.record_approve_verification
          ~config
          ~task_id
          ~verifier
          ~verification_id:state_vid
          ~notes
      | `Reject reason ->
        Verification_protocol.record_reject_verification
          ~config
          ~task_id
          ~verifier
          ~verification_id:state_vid
          ~reason)
  in
  let fsm_result =
    Coord.transition_task_r
      config
      ~agent_name:verifier
      ~task_id
      ~action
      ~prepare_verification_verdict
      ~notes:reason
      ~reason
      ()
  in
  match fsm_result with
  | Error err -> Error (Masc_domain.masc_error_to_string err)
  | Ok _ ->
    (match action with
     | Masc_domain.Approve_verification ->
       Verification_protocol.notify_approve_verification
         ~task_id
         ~verifier
         ~verification_id
         ~notes:reason
     | Masc_domain.Reject_verification ->
       Verification_protocol.notify_reject_verification
         ~task_id
         ~verifier
         ~verification_id
         ~reason
     | Masc_domain.Claim
     | Masc_domain.Start
     | Masc_domain.Done_action
     | Masc_domain.Cancel
     | Masc_domain.Release
     | Masc_domain.Submit_for_verification
     | Masc_domain.Submit_pr_evidence -> ());
    Ok
      (`Assoc
          [ "ok", `Bool true
          ; "task_id", `String task_id
          ; "verification_id", `String verification_id
          ; "decision", `String decision_name
          ; "verifier", `String verifier
          ])
;;

let dashboard_planning_http_json ~(config : Coord.config) : Yojson.Safe.t =
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

let dashboard_goals_tree_http_json ~(config : Coord.config) : Yojson.Safe.t =
  Dashboard_goals.dashboard_goals_tree_json ~config
;;

let dashboard_goals_snapshot_json ~(config : Coord.config) : Yojson.Safe.t =
  `Assoc
    [ "planning", dashboard_planning_http_json ~config
    ; "tree", dashboard_goals_tree_http_json ~config
    ]
;;


(* Composite fleet snapshot / runtime attention / recommended-actions
   extracted to [Server_dashboard_http_composite] (godfile decomp). *)
include Server_dashboard_http_composite

let dashboard_goal_detail_http_json ~(config : Coord.config) ~goal_id : Yojson.Safe.t =
  match Dashboard_goals.goal_detail_json ~config ~goal_id with
  | Ok json -> json
  | Error message ->
    `Assoc [ "ok", `Bool false; "error", `String message; "goal_id", `String goal_id ]
;;

let operator_action_http_json ~state ~sw ~clock request ~args =
  let actor =
    Server_auth.dashboard_actor_for_request
      ~base_path:state.Mcp_server.room_config.base_path
      request
  in
  let ctx : _ Operator_control.context =
    { config = state.Mcp_server.room_config
    ; agent_name = Option.value ~default:"dashboard" actor
    ; sw
    ; clock
    ; proc_mgr = state.Mcp_server.proc_mgr
    ; net = state.Mcp_server.net
    ; mcp_session_id = None
    }
  in
  Operator_control.action_json ?actor_hint:actor ctx args
;;

let operator_confirm_http_json ~state ~sw ~clock request ~args =
  let actor =
    Server_auth.dashboard_actor_for_request
      ~base_path:state.Mcp_server.room_config.base_path
      request
  in
  let ctx : _ Operator_control.context =
    { config = state.Mcp_server.room_config
    ; agent_name = Option.value ~default:"dashboard" actor
    ; sw
    ; clock
    ; proc_mgr = state.Mcp_server.proc_mgr
    ; net = state.Mcp_server.net
    ; mcp_session_id = None
    }
  in
  Operator_control.confirm_json ?actor_hint:actor ctx args
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
        state.Mcp_server.room_config)
  in
  let execution =
    slice "execution" (fun () -> dashboard_execution_http_json ~state ~sw ~clock request)
  in
  let planning =
    slice "planning" (fun () ->
      dashboard_planning_http_json ~config:state.Mcp_server.room_config)
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
  let goals =
    slice "goals" (fun () ->
      dashboard_goals_tree_http_json ~config:state.Mcp_server.room_config)
  in
  let goal_loop_status =
    slice "goal_loop_status" (fun () ->
      Dashboard_goal_loop.status_json ~base_path:state.Mcp_server.room_config.base_path ())
  in
  `Assoc
    [ "served_at", `String (Masc_domain.now_iso ())
    ; "milestone", `Int 1
    ; shell
    ; execution
    ; planning
    ; namespace_truth
    ; goals
    ; goal_loop_status
    ]
;;
