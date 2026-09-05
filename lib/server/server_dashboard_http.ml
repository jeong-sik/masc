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

let dashboard_namespace_truth_http_json =
  Server_dashboard_http_namespace_truth.dashboard_namespace_truth_http_json
;;

let dashboard_board_payload
      ?config
      ?hearth
      ?author_filter
      ?(sort_by = Board_dispatch.Hot)
      ?(exclude_system = false)
      ?(exclude_automation = false)
      ?(limit = 100)
      ?(offset = 0)
      ?voter
      ()
  : Dashboard_cache.cached_payload
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
      "board:memory:%s;%s;%s;%b;%b;%d;%d;%s;%s"
      (Option.value ~default:"-" hearth)
      (Option.value ~default:"-" author_filter)
      (board_sort_label sort_by)
      exclude_system
      exclude_automation
      limit
      offset
      config_key
      (Option.value ~default:"-" voter)
  in
  Dashboard_cache.get_or_compute_payload cache_key ~ttl:dashboard_projection_cache_ttl_s (fun () ->
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
      let posts_json =
        List.map
          (fun (post : Board.post) ->
             let author = Board.Agent_id.to_string post.author in
             let post_id = Board.Post_id.to_string post.id in
             let current_vote = board_current_vote_for_post ~voter ~post_id in
             board_post_dashboard_json
               ?current_vote
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


let dashboard_memory_http_payload ?config request : Dashboard_cache.cached_payload =
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
  dashboard_board_payload
    ?config
    ?hearth
    ?author_filter
    ~sort_by
    ~exclude_system
    ~exclude_automation
    ~limit
    ~offset
    ?voter
    ()
;;

let dashboard_memory_http_json ?config request : Yojson.Safe.t =
  (dashboard_memory_http_payload ?config request).json
;;


(** Read the resolved-history page bounds. [?limit=<rows>] caps the returned
    decisions and [?window=<minutes>] caps how far back they may be dated,
    matching the [?window=] idiom of {!dashboard_gate_tool_events_http_json}.
    Both are clamped by the approval queue, which owns the bounds; the clamp
    here only keeps a hostile query from allocating before that. [offset] and
    [status_filter] used to be parsed and cache-keyed here while the projection
    discarded them, which fragmented the cache across keys that computed
    identical payloads — they are gone rather than silently ignored. *)
let dashboard_gate_http_json request ~base_path : Yojson.Safe.t =
  let limit =
    int_query_param
      request
      "limit"
      ~default:Keeper_approval.Audit.recent_resolved_history_limit
    |> clamp ~min_v:1 ~max_v:Keeper_approval.Audit.recent_resolved_max_limit
  in
  let window_minutes =
    int_query_param
      request
      "window"
      ~default:Keeper_approval.Audit.recent_resolved_default_window_minutes
    |> clamp
         ~min_v:Keeper_approval.Audit.recent_resolved_min_window_minutes
         ~max_v:Keeper_approval.Audit.recent_resolved_max_window_minutes
  in
  let force = bool_query_param request "force" ~default:false in
  let approval_queue_revision =
    Keeper_approval_queue.store_revision_for_workspace ~base_path
  in
  let cache_key =
    Printf.sprintf
      "gate:%s;%d;%d;%d"
      base_path
      limit
      window_minutes
      approval_queue_revision
  in
  let compute () =
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Dashboard_gate.dashboard_json ~base_path ~limit ~window_minutes)
  in
  if force then Dashboard_cache.invalidate cache_key;
  Dashboard_cache.get_or_compute cache_key ~ttl:dashboard_projection_cache_ttl_s compute
;;

(** Read the optional [?window=<minutes>] query param.
    Defaults to 60 minutes; clamped to [5..1440]. *)
let dashboard_gate_tool_events_http_json request ~base_path : Yojson.Safe.t =
  let window =
    int_query_param request "window" ~default:60 |> clamp ~min_v:5 ~max_v:1440
  in
  Dashboard_gate_metrics.gate_tool_events_json
    ~base_path
    ~window_minutes:window
    ()
;;

(* /api/v1/dashboard/proof was measured at 28-60s (timeout) under
   live load. The verification projection walks the on-disk request store, so
   an uncached computation must not run on the Eio main domain.

   Same fix pattern as PR #18991 / #18993 / #18994: wrap in
   [Dashboard_cache.get_or_compute] for stale-while-revalidate and
   push the compute through [Domain_pool_ref.submit_io_or_inline]
   so the main domain keeps serving requests during refresh. *)
let dashboard_proof_compute ~config ~limit () : Yojson.Safe.t =
  let base_path = config.Workspace.base_path in
  (* Single disk scan via [proof_compose]; the historical
     [summary_json] + [requests_json] sequence walked the verification
     store twice per refresh. *)
  let verification_summary, verification_requests =
    Dashboard_verification.proof_compose ~base_path ~limit ()
  in
  let proof_source ~id ~label ~route =
    `Assoc [ "id", `String id; "label", `String label; "route", `String route ]
  in
  let proof_sources =
    [
      proof_source ~id:"verification_summary"
        ~label:"Verification submission summary"
        ~route:"/api/v1/verification/summary";
      proof_source ~id:"verification_requests"
        ~label:"Verification request evidence"
        ~route:"/api/v1/verification/requests";
      proof_source ~id:"tlc_results"
        ~label:"TLA+ verification logs"
        ~route:"/api/v1/verification/tlc-results";
      proof_source ~id:"execution_trust"
        ~label:"Execution trust provenance"
        ~route:"/api/v1/dashboard/execution-trust";
    ]
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

(* Both the HTTP/1 router and the H2 gateway serve this projection, and the H2
   registration carries a comment requiring the two to stay identical. Caching
   at each call site would have been two copies of the policy and the first
   chance for them to drift, so the cache lives with the projection and both
   routes call this.

   The route was offloaded but uncached, so a polling dashboard re-ran the
   schedule scan every time: measured 272 ms cold and 204 ms warm for a 96 KB
   response, the second pass no cheaper than the first. Its siblings
   (briefing/sections, tool-quality) already pair the offload with the cache;
   this one only ever had half the pair.

   [live_cache_ttl_s] is the 30 s tier documented for "frequently-changing data
   such as active keeper state" — schedule state belongs there rather than in
   the 120 s projection tier. The aggregate response takes no selectors, so
   base_path is the whole key. Exact lookups bypass this aggregate cache below. *)
let dashboard_scheduled_automation_http_json ~(config : Workspace.config) :
  Yojson.Safe.t
  =
  let cache_key =
    Server_dashboard_http_core_cache.dashboard_query_cache_key
      config
      "scheduled_automation"
      []
  in
  Dashboard_cache.get_or_compute
    cache_key
    ~ttl:Server_dashboard_http_core_cache.live_cache_ttl_s
    (fun () ->
      Domain_pool_ref.submit_io_or_inline (fun () ->
        Server_dashboard_schedule_projection.scheduled_automation_dashboard_json
          config))
;;

let dashboard_scheduled_automation_query_http_json
  ~(config : Workspace.config)
  (request : Httpun.Request.t)
  : Yojson.Safe.t
  =
  match Server_utils.query_param request "schedule_id" with
  | None ->
    (* A target selector is already narrowed by its target, so it bypasses the
       aggregate's shared cache the same way the exact lookup does: a
       client-controlled selector in a cache key is a key per caller. *)
    (match Server_utils.query_param request "payload_target" with
     | None -> dashboard_scheduled_automation_http_json ~config
     | Some payload_target ->
       Domain_pool_ref.submit_io_or_inline (fun () ->
         Server_dashboard_schedule_projection.scheduled_automation_dashboard_json
           ~payload_target
           config))
  | Some schedule_id ->
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Server_dashboard_schedule_projection.scheduled_automation_exact_lookup_json
        config
        (* NDT-OK: the request boundary is where wall-clock enters, so the
           projection stays a pure function of (state, now). *)
        ~now:(Unix.gettimeofday ())
        ~schedule_id)
;;

let dashboard_proof_http_json ~config request : Yojson.Safe.t =
  let limit = int_query_param request "limit" ~default:25 |> clamp ~min_v:1 ~max_v:100 in
  let key =
    Printf.sprintf "dashboard.proof:%s;%d" config.Workspace.base_path limit
  in
  Dashboard_cache.get_or_compute key ~ttl:dashboard_projection_cache_ttl_s (fun () ->
    Domain_pool_ref.submit_io_or_inline (fun () ->
      dashboard_proof_compute ~config ~limit ()))
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
let approval_resolve_reject_reason_required_message =
  "reason is required when decision is 'reject'"

type approval_resolve_decision =
  | Approval_resolve_approve
  | Approval_resolve_reject of string

let approval_resolve_decision_name = function
  | Approval_resolve_approve -> approval_resolve_approve_name
  | Approval_resolve_reject _ -> approval_resolve_reject_name
;;

let approval_resolve_decision_to_queue_decision = function
  | Approval_resolve_approve -> Keeper_approval_queue_rules_types.Decision.Approve
  | Approval_resolve_reject reason -> Keeper_approval_queue_rules_types.Decision.Reject reason
;;

let approval_resolve_decision_of_json args =
  match Safe_ops.json_string_opt approval_resolve_decision_field args with
  | None -> Error (Bad_request approval_resolve_decision_required_message)
  | Some raw ->
    (match raw |> String.trim |> String.lowercase_ascii with
     | name when String.equal name approval_resolve_approve_name ->
       Ok Approval_resolve_approve
     | name when String.equal name approval_resolve_reject_name ->
       (* A refusal the keeper cannot read is a refusal it cannot answer:
          polisher spent 20+ turns re-sending echo ok against the constant
          "dashboard rejected approval" because nothing said what was
          missing. An absent reason is a bad request, not a default. *)
       (match
          Safe_ops.json_string_opt approval_resolve_reason_field args
          |> Option.map String.trim
        with
        | None | Some "" ->
          Error (Bad_request approval_resolve_reject_reason_required_message)
        | Some reason -> Ok (Approval_resolve_reject reason))
     | _ -> Error (Bad_request approval_resolve_decision_invalid_message))
;;

let approval_resolve_http_error_to_string = function
  | Bad_request msg -> msg
  | Gone err -> Keeper_approval_queue.resolve_error_to_string err
  | Unavailable err -> Keeper_approval_queue.resolve_error_to_string err
;;

let dashboard_gate_resolve_http_json ~base_path ~created_by ~(args : Yojson.Safe.t)
  : (Yojson.Safe.t, approval_resolve_http_error) result
  =
  match Safe_ops.json_string_opt "id" args with
  | None -> Error (Bad_request "id is required")
  | Some id ->
    let remember_rule =
      Safe_ops.json_bool_opt "remember_rule" args |> Option.value ~default:false
    in
    let rule_expires_at = Safe_ops.json_float_opt "rule_expires_at" args in
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
            ~base_path
            ~id
            ~decision
            ~remember_rule
            ?rule_expires_at
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
                ; ( "audit_receipts"
                  , `List
                      (List.map
                         Keeper_approval.Audit.receipt_to_yojson
                         result.audit_receipts) )
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

let dashboard_gate_retry_http_json ~base_path ~requested_by ~(args : Yojson.Safe.t) =
  let ( let* ) = Result.bind in
  let* fields =
    match args with
    | `Assoc fields -> Ok fields
    | _ -> Error "retry request must be an object"
  in
  let allowed =
    [ "id"
    ; "input_hash"
    ; "sequence"
    ; "exact_attempt"
    ; "summary_attempt_disposition"
    ]
  in
  let rec duplicate seen = function
    | [] -> None
    | (key, _) :: rest ->
      if List.mem key seen then Some key else duplicate (key :: seen) rest
  in
  let* () =
    match duplicate [] fields with
    | Some field -> Error ("retry request contains duplicate field " ^ field)
    | None ->
      (match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
       | Some (field, _) ->
         Error ("retry request contains unsupported field " ^ field)
       | None -> Ok ())
  in
  let required field =
    match List.assoc_opt field fields with
    | Some value -> Ok value
    | None -> Error ("retry request." ^ field ^ " is required")
  in
  let* id_json = required "id" in
  let* id =
    match id_json with
    | `String value when String.trim value <> "" -> Ok value
    | _ -> Error "retry request.id must be a non-blank string"
  in
  let* input_hash_json = required "input_hash" in
  let* expected_input_hash =
    match input_hash_json with
    | `String value when Keeper_approval_queue_rules_types.is_lowercase_sha256 value ->
      Ok value
    | _ -> Error "retry request.input_hash must be a lowercase SHA-256"
  in
  let* sequence_json = required "sequence" in
  let* expected_sequence =
    match sequence_json with
    | `Int value when value > 0 -> Ok value
    | _ -> Error "retry request.sequence must be a positive integer"
  in
  let* exact_attempt_json = required "exact_attempt" in
  let* expected_exact_attempt =
    Keeper_approval_queue_rules_types.exact_attempt_state_of_yojson_with_error
      exact_attempt_json
  in
  let* disposition_json = required "summary_attempt_disposition" in
  let* expected_disposition =
    Keeper_approval_queue_rules_types.summary_attempt_disposition_of_yojson_with_error
      disposition_json
  in
  let* () =
    match expected_disposition with
    | Keeper_approval_queue_rules_types.Summary_attempt_identity_unbound
    | Keeper_approval_queue_rules_types.Summary_attempt_persistence_uncertain ->
      Ok ()
    | Keeper_approval_queue_rules_types.Summary_attempt_pre_worker_unavailable _ ->
      Ok ()
    | _ -> Error "retry request disposition is not operator-rearmable"
  in
  match
    Keeper_gate.retry_blocked_auto_judge
      ~base_path
      ~requested_by
      ~expected_input_hash
      ~expected_sequence
      ~expected_exact_attempt
      ~expected_disposition
      id
  with
  | Error _ as error -> error
  | Ok () -> Ok (`Assoc [ "ok", `Bool true; "id", `String id ])
;;

let dashboard_gate_rule_delete_http_json ~base_path ~(args : Yojson.Safe.t)
  : (Yojson.Safe.t, string) result
  =
  match Safe_ops.json_string_opt "id" args with
  | None -> Error "id is required"
  | Some id ->
    (match Keeper_approval_queue_rules.delete_rule ~base_path ~id () with
     | Ok deleted ->
         let audit_receipt =
           Keeper_approval.Audit.record_rule
             ~base_path
             ~event_type:Keeper_approval.Audit.Rule_deleted
             deleted
         in
         Ok
           (`Assoc
               [ "ok", `Bool true
               ; "id", `String deleted.id
               ; "audit", Keeper_approval.Audit.receipt_to_yojson audit_receipt
               ])
       | Error error ->
         Error (Keeper_approval_queue_rules_types.rule_store_error_to_string error))
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

let dashboard_planning_http_json ~(config : Workspace.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let rollup = Goal_store.compute_rollup goals in
  (* RFC-0387 (stage 1): the verification ledger joins each goal at the API
     boundary (goal_to_yojson is the persistence codec and stays untouched).
     The ledger is loaded ONCE per request and joined in memory; a store that
     does not decode renders the explicit [ledger_error] marker per goal —
     never the pre-verification default, which would disguise corruption as
     "not verified yet". *)
  let records = Goal_verification.load_records config in
  let goal_json (goal : Goal_store.goal) =
    let verification =
      match records with
      | Error detail -> Goal_verification.ledger_error_to_yojson detail
      | Ok records ->
        (match
           List.find_opt
             (fun (record : Goal_verification.record) ->
               String.equal record.goal_id goal.id)
             records
         with
         | Some record -> record
         | None -> Goal_verification.default_record ~goal_id:goal.id)
        |> Goal_verification.record_to_yojson
    in
    match Goal_store.goal_to_yojson goal with
    | `Assoc fields ->
      `Assoc (fields @ [ "verification", verification ])
    | json -> json
  in
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
    ; "goals", `List (List.map goal_json goals)
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

(* Composite keeper JSON, goal collect_* helpers, and error taxonomy are
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
             (Mcp_server.publication_recovery_availability_provider state)
           ())
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
  `Assoc
    [ "served_at", `String (Masc_domain.now_iso ())
    ; "milestone", `Int 1
    ; shell
    ; execution
    ; planning
    ; namespace_truth
    ]
;;

let warm_dashboard_surfaces (state : Mcp_server.server_state) =
  let t0 = Time_compat.now () in
  let config = Mcp_server.workspace_config state in
  let base_path = config.Workspace.base_path in
  let warm_board () =
    try
      let t_start = Time_compat.now () in
      ignore (dashboard_board_payload ~config ~limit:100 ~offset:0 ());
      Log.Dashboard.info "board surface pre-warmed (%.1fms)" ((Time_compat.now () -. t_start) *. 1000.0)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Log.Dashboard.warn "board pre-warm failed: %s" (Printexc.to_string exn)
  in
  let warm_planning () =
    try
      let t_start = Time_compat.now () in
      let cache_key = Printf.sprintf "planning:%s" base_path in
      ignore
        (Dashboard_cache.get_or_compute cache_key
           ~ttl:Server_dashboard_http_core_cache.standard_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_planning_http_json ~config)));
      Log.Dashboard.info "planning surface pre-warmed (%.1fms)" ((Time_compat.now () -. t_start) *. 1000.0)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Log.Dashboard.warn "planning pre-warm failed: %s" (Printexc.to_string exn)
  in
  let warm_config () =
    try
      let t_start = Time_compat.now () in
      ignore
        (Dashboard_cache.get_or_compute "config_introspect"
           ~ttl:Server_dashboard_http_core_cache.config_cache_ttl_s
           Env_config_introspect.to_json);
      Log.Dashboard.info "config surface pre-warmed (%.1fms)" ((Time_compat.now () -. t_start) *. 1000.0)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Log.Dashboard.warn "config pre-warm failed: %s" (Printexc.to_string exn)
  in
  let warm_keeper_memory_health () =
    try
      let t_start = Time_compat.now () in
      let cache_key = Printf.sprintf "keeper_memory_health:%s" base_path in
      ignore
        (Dashboard_cache.get_or_compute cache_key
           ~ttl:Server_dashboard_http_core_cache.standard_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Server_dashboard_http_keeper_memory_health.keeper_memory_health_http_json ~base_path)));
      Log.Dashboard.info "keeper-memory-health surface pre-warmed (%.1fms)" ((Time_compat.now () -. t_start) *. 1000.0)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Log.Dashboard.warn "keeper-memory-health pre-warm failed: %s" (Printexc.to_string exn)
  in
  Eio.Fiber.all
    [ (fun () -> warm_shell_cache state)
    ; warm_board
    ; warm_planning
    ; warm_config
    ; warm_keeper_memory_health
    ];
  Log.Dashboard.info "all primary dashboard surfaces pre-warmed in parallel (%.1fms total)"
    ((Time_compat.now () -. t0) *. 1000.0)
;;

