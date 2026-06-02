(** Server_dashboard_http_agent_api — Agent API HTTP handlers.

    Registers GET handlers for the agent observability surface,
    extracted from [server_routes_http_routes_dashboard.ml]:

    - [GET /api/v1/agent-activity] — per-agent tool call stats from telemetry
    - [GET /api/v1/tool-metrics] — aggregate tool metrics
    - [GET /api/v1/agent-timeline] — per-agent timeline view
    - [GET /api/v1/agent-relations] — agent-relation graph

    Internal request/response helpers are intentionally hidden — only
    the route registration entry point is exposed. *)

val add_agent_api_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
