(** Server_dashboard_http_delete_actions — POST handlers for
    dashboard delete/sweep endpoints.

    Extracted from {!Server_routes_http_routes_dashboard}. Registers
    admin-only routes:
    - [/api/v1/dashboard/board/delete] — delete one board post
    - [/api/v1/dashboard/tasks/delete] — delete one task
    - [/api/v1/dashboard/goals/delete] — delete one goal
    - [/api/v1/dashboard/goals/sweep] — run {!Goal_janitor} *)

(** [add_delete_action_routes router] returns [router] with the four
    delete/sweep endpoints appended. Each route requires
    {!Types.CanAdmin} via [Server_auth.with_token_permission_auth]. *)
val add_delete_action_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
