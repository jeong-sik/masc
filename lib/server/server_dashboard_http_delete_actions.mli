(** Server_dashboard_http_delete_actions — POST handlers for
    dashboard delete/sweep endpoints.

    Extracted from {!Server_routes_http_routes_dashboard}. Registers
    admin-only routes:
    - [/api/v1/dashboard/board/delete] — delete one board post
    - [/api/v1/dashboard/tasks/delete] — delete one task
    - [/api/v1/dashboard/goals/delete] — delete one goal
    - [/api/v1/dashboard/agents/purge] — hard-delete one agent/keeper
    - [/api/v1/dashboard/goals/sweep] — run {!Goal_janitor}

    Board moderation routes (Phase 2):
    - [POST /api/v1/dashboard/board/moderation/flag] — flag a post for review
    - [GET  /api/v1/dashboard/board/moderation/queue] — list pending/resolved queue entries
    - [POST /api/v1/dashboard/board/moderation/action] — take a moderation action *)

(** [add_delete_action_routes router] returns [router] with the five
    delete/sweep endpoints and three board moderation endpoints appended.
    Each route requires {!Masc_domain.CanAdmin} via
    [Server_auth.with_token_permission_auth]. *)
val add_delete_action_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
