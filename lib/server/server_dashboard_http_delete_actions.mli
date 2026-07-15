(** Server_dashboard_http_delete_actions — POST handlers for
    dashboard delete/sweep endpoints.

    Extracted from {!Server_routes_http_routes_dashboard}. Registers
    admin-only routes:
    - [/api/v1/dashboard/board/delete] — delete one board post
    - [/api/v1/dashboard/tasks/delete] — delete one task
    - [/api/v1/dashboard/agents/purge] — delete an exact agent or accept a
      durable Keeper purge operation

    Board moderation routes (Phase 2):
    - [POST /api/v1/dashboard/board/moderation/flag] — flag a post for review
    - [GET  /api/v1/dashboard/board/moderation/queue] — list pending/resolved queue entries
    - [POST /api/v1/dashboard/board/moderation/action] — take a moderation action *)

(** [add_delete_action_routes router] returns [router] with the delete
    endpoints and three board moderation endpoints appended.
    Each route requires {!Masc_domain.CanAdmin} via
    [Server_auth.with_token_permission_auth]. *)
val add_delete_action_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t

(** Process-boundary completion handler for durable Keeper lifecycle
    operations. Dashboard purge artifacts are removed strictly and
    repeat-safely; non-dashboard actions delegate to the supervisor cleanup
    handler. *)
val handle_keeper_lifecycle_completion :
  Workspace.config ->
  Keeper_shutdown_types.t ->
  Keeper_shutdown_types.completion_action ->
  (unit, string) result

module For_testing : sig
  val purge_dashboard_keeper_artifacts :
    Workspace.config -> Keeper_shutdown_types.t -> (unit, string) result
end
