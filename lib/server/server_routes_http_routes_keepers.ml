(* server_routes_http_routes_keepers — HTTP routes for keepers.

   [/api/v1/keepers_bulk/*] holds the fleet-wide operations and
   [/api/v1/keepers/*] the per-keeper reads, mutations and lifecycle
   actions. Server_routes_http_routes_dashboard.add_routes registers this
   group in the middle of its own pipeline. *)

open Server_auth
open Server_routes_http_keeper_stream

module Http = Http_server_eio
module Keeper_api = Server_dashboard_http_keeper_api
module Keeper_chat_operations = Server_dashboard_http_keeper_chat_operations
module Keeper_portrait = Server_dashboard_http_keeper_portrait
module Keeper_items = Server_dashboard_http_keeper_items
module Keeper_event_queue_operator =
  Server_dashboard_http_keeper_event_queue_operator
module Keeper_shutdown_reconciliation =
  Server_dashboard_http_keeper_shutdown_reconciliation

let add_routes ~sw ~clock router =
  router
  (* Bulk keeper directive — operator can pause/resume/wakeup N keepers in
     one round-trip with a single batch cache invalidate at the end. The
     URL prefix is intentionally outside [/api/v1/keepers/] so it does not
     collide with the per-name [prefix_post] catch-all below. *)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/keepers_bulk/directive" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             Keeper_api.handle_keeper_bulk_directive_post
               ~sw ~clock state agent_name req reqd body_str))

  (* Fleet-wide event-queue bulk cancel — dry-run by default, explicit confirm
     to execute, backup before mutation. The URL prefix is intentionally
     outside [/api/v1/keepers/] so it does not collide with the per-name
     [prefix_post] catch-all below. *)
  |> Server_route.post (Server_route.Token_permission Server_dashboard_http_keeper_event_queue_bulk.permission) "/api/v1/keepers_bulk/event-queue" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             Server_dashboard_http_keeper_event_queue_bulk.handle_post
               state
               ~actor:agent_name
               req
               reqd
               body_str))

  |> Server_route.post (Server_route.Tool_actor { tool_name = Keeper_tool_name.(to_string Keeper_delegate) }) "/api/v1/keepers/chat/stream" (fun state submitted_by request reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           let admitted_body =
             try
               match Workspace.validate_expected_workspace
                   ~config:(Mcp_server.workspace_config state)
                   (Yojson.Safe.from_string body_str) with
               | Ok payload -> Ok (Yojson.Safe.to_string payload)
               | Error error -> Error (Workspace.expected_workspace_error_message error)
             with Yojson.Json_error _ -> Error "invalid JSON body"
           in
           match
             Result.bind admitted_body
               (parse_keeper_chat_stream_request
                  ~media_store:
                    (Tool_blob_media_store.of_base_path
                       ~base_path:(Mcp_server.workspace_config state).Workspace.base_path))
           with
           | Ok payload ->
               handle_keeper_chat_stream
                 ~sw
                 ~clock
                 ~submitted_by
                 state
                 request
                 reqd
                 payload
           | Error message ->
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (keeper_chat_stream_error_json message)
         )
       )

  (* Keeper GET sub-routes: /config, /chat/history, /trajectory *)
  |> Server_route.prefix_get (Server_route.Self_authenticated Route_access.Subpath_dispatch) "/api/v1/keepers/" (fun request reqd ->
       match Keeper_items.route (Http.Request.path request) with
       | Some name ->
         with_token_permission_auth ~permission:Keeper_items.permission
           (fun state _actor req reqd -> Keeper_items.handle_get state req reqd name)
           request reqd
       | None ->
       match Keeper_portrait.route (Http.Request.path request) with
       | Some name ->
         with_public_read
           (fun state req reqd -> Keeper_portrait.handle_get state req reqd name)
           request reqd
       | None ->
       match Keeper_shutdown_reconciliation.route (Http.Request.path request) with
       | Some target ->
         with_token_permission_auth ~permission:Keeper_shutdown_reconciliation.permission
           (fun state _actor req reqd ->
             Keeper_shutdown_reconciliation.handle_get state req reqd target)
           request reqd
       | None ->
       if Http.Request.path request = Server_dashboard_http_hitl_recover.uncertain_path then
         with_token_permission_auth ~permission:Server_dashboard_http_hitl_recover.permission
           (fun state _actor req reqd -> Server_dashboard_http_hitl_recover.handle_uncertain_get state req reqd)
           request reqd
       else
       match Server_dashboard_http_keeper_child_content.route (Http.Request.path request) with
       | Some route ->
         with_token_permission_auth
           ~permission:Server_dashboard_http_keeper_child_content.permission
           (fun state _agent_name req reqd ->
             Server_dashboard_http_keeper_child_content.handle_get state req reqd route)
           request reqd
       | None ->
       match Server_dashboard_http_keeper_native_tasks.route (Http.Request.path request) with
       | Some route ->
         with_token_permission_auth
           ~permission:Server_dashboard_http_keeper_native_tasks.permission
           (fun state _agent_name req reqd ->
             Server_dashboard_http_keeper_native_tasks.handle_get state req reqd route)
           request reqd
       | None ->
       match Server_dashboard_http_keeper_execution_history.route (Http.Request.path request) with
       | Some route ->
         with_token_permission_auth
           ~permission:Server_dashboard_http_keeper_execution_history.permission
           (fun state _agent_name req reqd ->
             Server_dashboard_http_keeper_execution_history.handle_get state req reqd route)
           request reqd
       | None ->
       match Keeper_chat_operations.get_route (Http.Request.path request) with
       | Some route ->
         let handle state req reqd =
           Keeper_chat_operations.handle_get state req reqd route
         in
         (match route with
          | Operation_list _ | Operation_exact _ ->
            with_permission_auth
              ~permission:(Keeper_chat_operations.get_permission route)
              handle request reqd
          | Chat_events _ | Turn_events _ ->
            with_token_permission_auth
              ~permission:(Keeper_chat_operations.get_permission route)
              (fun state _agent_name req reqd -> handle state req reqd)
              request reqd)
       | None ->
         (match
            Keeper_api.keeper_get_permission
              ~include_thinking:
                (Server_utils.bool_query_param request "include_thinking"
                   ~default:false)
              (Http.Request.path request)
          with
          | Some permission ->
           with_token_permission_auth ~permission
             (fun state _agent_name req reqd ->
               Keeper_api.handle_keeper_get_subroutes state req request reqd
             ) request reqd
          | None ->
           with_public_read (fun state req reqd ->
             Keeper_api.handle_keeper_get_subroutes state req request reqd
           ) request reqd))

  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/keepers/turn/run-next" (fun state actor req reqd -> Server_routes_http_keeper_control.handle_keeper_run_next state ~actor req reqd)

  (* Fleet Keeper efficiency month view, same read authority as the
     per-keeper [/metrics] tail: month aggregates over the cost and
     tool-call ledgers through the RFC-0162 boundary cache. *)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanReadState)
       Server_dashboard_http_keeper_efficiency.route_path
       (fun state _agent_name req reqd ->
          Server_dashboard_http_keeper_efficiency.handle_get state req reqd)

  |> Server_route.post (Server_route.Tool_actor { tool_name = Keeper_tool_name.(to_string Keeper_delegate_cancel) }) "/api/v1/keepers/turn/interrupt" (fun state actor request reqd ->
         Server_routes_http_keeper_control.handle_keeper_turn_interrupt ~actor state request reqd)

  (* Answers a tool call the keeper is holding. Same authority as interrupting
     a turn: both decide what a running turn is allowed to do next. The route
     carries its own catalog auth key (keeper_tool_approval_route) rather than
     borrowing a dispatchable tool's name, so the permission it enforces stays
     reviewable on its own terms. *)
  |> Server_route.post (Server_route.Tool_actor { tool_name = "keeper_tool_approval_route" }) "/api/v1/keepers/tool-approval" (fun state actor request reqd ->
         Server_routes_http_keeper_control.handle_keeper_tool_approval ~actor state request reqd)

  (* What one Keeper is waiting on a human for. *)
  |> Server_route.get (Server_route.Tool { tool_name = "masc_ask_status" }) "/api/v1/keepers/asks" (fun state request reqd ->
         Server_routes_http_keeper_asks.handle_keeper_asks_list ~clock state request reqd)

  (* Answers a Keeper's question. The operator may be at any surface; the
     log settles concurrent submissions on first write. *)
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_ask" }) "/api/v1/keepers/ask-answer" (fun state actor request reqd ->
         Server_routes_http_keeper_asks.handle_keeper_ask_answer ~actor state request reqd)

  (* Lists the tool calls keepers are holding, so a wait whose owning stream
     watcher is gone can still be answered instead of only timing out
     (masc#30034). Read authority follows the operator snapshot (public
     read): the listing names what is being asked; answering stays behind
     the authed POST above. *)
  |> Server_route.get Server_route.Public_read "/api/v1/keepers/tool-approvals" (fun state request reqd ->
         Server_routes_http_keeper_control.handle_keeper_tool_approvals_list state request reqd)

  (* Which keepers are mid-turn right now. Read-only Owner projection with
     the same read authority as the listing above: it names activity, and
     every mutation stays behind its own authed route. *)
  |> Server_route.get Server_route.Public_read "/api/v1/keepers/turns" (fun state request reqd ->
         Server_routes_http_keeper_control.handle_keeper_turns_list state request reqd)

  (* The per-keeper approval stance the gate consults per call. Reading the
     overrides is a public-read projection like the listing above; setting
     one decides what a running turn may do next, so it carries the same
     authority as answering a held call (and its own catalog auth key,
     keeper_tool_approval_mode_route). *)
  |> Server_route.get Server_route.Public_read "/api/v1/keepers/tool-approval-mode" (fun state request reqd ->
         Server_routes_http_keeper_control.handle_keeper_tool_approval_mode_get state request reqd)
  |> Server_route.post (Server_route.Tool_actor { tool_name = "keeper_tool_approval_mode_route" }) "/api/v1/keepers/tool-approval-mode" (fun state agent_name request reqd ->
           Server_routes_http_keeper_control.handle_keeper_tool_approval_mode_set ~actor:agent_name state request
             reqd)

  (* Keeper POST sub-routes. *)
  |> Server_route.prefix_post (Server_route.Self_authenticated Route_access.Subpath_dispatch) "/api/v1/keepers/" (fun request reqd ->
       match
         Server_dashboard_http_hitl_recover.route (Http.Request.path request)
       with
       | Some approval_id ->
         with_token_permission_auth
           ~permission:Server_dashboard_http_hitl_recover.permission
           (fun state actor req reqd ->
              Http.Request.read_body_async reqd (fun body ->
                Server_dashboard_http_hitl_recover.handle_post
                  state
                  ~actor
                  ~approval_id
                  req
                  reqd
                  body))
            request reqd
       | None ->
       if Http.Request.path request = Server_dashboard_http_hitl_recover.journal_restore_path then
         with_token_permission_auth
           ~permission:Server_dashboard_http_hitl_recover.permission
           (fun state _actor req reqd ->
             Server_dashboard_http_hitl_recover.handle_journal_restore state req reqd)
           request reqd
       else
       match Keeper_shutdown_reconciliation.route (Http.Request.path request) with
       | Some target ->
         with_token_permission_auth ~permission:Keeper_shutdown_reconciliation.permission
           (fun state actor req reqd ->
             Http.Request.read_body_async reqd (fun body ->
               Keeper_shutdown_reconciliation.handle_post state ~actor req reqd target body))
           request reqd
       | None ->
       match Keeper_chat_operations.mutation_route (Http.Request.path request) with
       | Some route ->
         (* Queue control follows chat submission's credential and same-origin
            policy, including workspaces that do not require a token. *)
         with_tool_auth
           ~tool_name:Keeper_tool_name.(to_string Keeper_delegate)
           (fun state req reqd ->
             Http.Request.read_body_async reqd (fun body_str ->
               Keeper_chat_operations.handle_mutation
                 state
                 req
                 reqd
                 route
                 body_str))
           request
           reqd
       | None ->
       match
         Server_dashboard_http_keeper_memory_cleanup.route
           (Http.Request.path request)
       with
       | Some target ->
         with_token_permission_auth
           ~permission:Server_dashboard_http_keeper_memory_cleanup.permission
           (fun state actor req reqd ->
             Http.Request.read_body_async reqd (fun body_str ->
               Server_dashboard_http_keeper_memory_cleanup.handle_post
                 state
                 ~actor
                 req
                 reqd
                 target
                 body_str))
           request
           reqd
       | None ->
       match Keeper_event_queue_operator.route (Http.Request.path request) with
       | Some keeper_name ->
         with_token_permission_auth
           ~permission:Keeper_event_queue_operator.operator_permission
           (fun state agent_name req reqd ->
             Http.Request.read_body_async reqd (fun body_str ->
               Keeper_event_queue_operator.handle_post
                 state
                 ~actor:agent_name
                 req
                 reqd
                 ~keeper_name
                 body_str))
           request reqd
       | None ->
       match Keeper_api.classify_keeper_post_route (Http.Request.path request) with
       | Keeper_api.Keeper_post_board_attention_quarantine_recovery
           { keeper_name; partition_id } ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_board_attention_quarantine_recovery_post
                   state
                   agent_name
                   req
                   reqd
                   ~keeper_name
                   ~raw_partition_id:partition_id
                   body_str))
             request reqd
       | Keeper_api.Keeper_post_config ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_config_post ~sw ~clock state agent_name req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_secrets ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_secrets_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_github_login ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Keeper_api.handle_keeper_github_login_post ~clock state req reqd)
             request reqd
       | Keeper_api.Keeper_post_github_token ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_github_token_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_identity_refresh ->
           (* Reads from a provider and writes a catalog into this keeper's
              own state, so it carries the same authority as starting the
              login that produced the credential. *)
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_identity_refresh_post ~clock state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_identity_switch ->
           (* Decides whether this keeper's turns are handed that provider's
              tools at all, so it carries the same authority as the attach
              that produced them. The operator name feeds the audit row. *)
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_identity_switch_post state
                   ~actor:agent_name req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_oauth_login ->
           (* Same authority as writing a secret by hand: what this begins
              ends with credentials in that keeper's scope. *)
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_oauth_login_post ~clock state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_boot ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Keeper_api.handle_keeper_lifecycle_post ~sw ~clock ~tool_name:"masc_keeper_up"
                 ~action:"boot" state agent_name req reqd
             ) request reqd
       | Keeper_api.Keeper_post_up ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                   Keeper_api.handle_keeper_lifecycle_post ~body_str ~sw ~clock
                     ~tool_name:"masc_keeper_up" ~action:"up"
                     state agent_name req reqd
               )
             ) request reqd
       | Keeper_api.Keeper_post_shutdown ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Keeper_api.handle_keeper_lifecycle_post ~sw ~clock ~tool_name:"masc_keeper_down"
                 ~action:"shutdown" state agent_name req reqd
             ) request reqd
       | Keeper_api.Keeper_post_reset ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Keeper_api.handle_keeper_lifecycle_post ~sw ~clock ~tool_name:"masc_keeper_reset"
                 ~action:"reset" state agent_name req reqd
             ) request reqd
       | Keeper_api.Keeper_post_clear ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_lifecycle_post ~body_str ~sw ~clock
                   ~tool_name:"masc_keeper_clear" ~action:"clear"
                   state agent_name req reqd
               )
             ) request reqd
       | Keeper_api.Keeper_post_checkpoints ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_checkpoints_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_directive ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_directive_post
                   ~sw ~clock state agent_name req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_paused_work ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_paused_work_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_fusion ->
           with_tool_auth ~tool_name:"masc_fusion"
             (fun state req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_fusion_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_operator_note ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_operator_note_post
                   state agent_name req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_unknown ->
           Server_dashboard_http_keeper_api_post.respond_error ~status:`Not_found reqd "not found")
