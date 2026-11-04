(** Server_dashboard_http_agent_api — Agent API HTTP handlers.

    Registers GET handlers for the agent observability surface,
    extracted from [server_routes_http_routes_dashboard.ml]:

    - [GET /api/v1/agent-activity] — per-agent tool call stats from telemetry
    - [GET /api/v1/tool-metrics] — aggregate tool metrics
    - [GET /api/v1/tool-metrics/series] — hourly or daily totals of tool calls
    - [GET /api/v1/agent-timeline] — per-agent timeline view
    - [GET /api/v1/agent-relations] — agent-relation graph

    Internal request/response helpers are intentionally hidden — only
    the route registration entry point is exposed. *)

(** Read an absent value as [default], otherwise require a finite positive
    decimal number. *)
val positive_float_param
  :  name:string
  -> default:float
  -> string option
  -> (float, string) Result.t

val positive_int_param
  :  name:string
  -> default:int
  -> string option
  -> (int, string) Result.t
(** Read an absent value as [default], otherwise require positive decimal
    digits. *)

val signed_int_param
  :  name:string
  -> default:int
  -> string option
  -> (int, string) Result.t
(** Read an absent value as [default], otherwise require decimal digits with
    an optional leading [-]. *)

val tool_series_max_tool_name_bytes : int
(** The longest [tool] filter of [GET /api/v1/tool-metrics/series]. *)

val tool_name_param : string option -> (string option, string) Result.t
(** Read an absent [tool] filter as no filter, otherwise require 1 to
    {!tool_series_max_tool_name_bytes} bytes with no leading or trailing
    whitespace. The response cache trims every value of a request, so a name
    that trimming would change is refused instead of read as another name. *)

val agent_activity_http_json :
  config:Masc.Workspace.config -> hours:float -> Yojson.Safe.t
(** Per-agent tool-call rollup for [GET /api/v1/agent-activity], cached per
    [(base_path, hours)] and computed off the HTTP domain. Exposed so the cache
    policy can be exercised without an HTTP round trip. *)

val add_agent_api_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
