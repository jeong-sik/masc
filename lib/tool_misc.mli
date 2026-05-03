
(** Tool_misc — miscellaneous MASC tool handlers.

    Dispatches: transport_status, websocket_discovery, webrtc,
    dashboard, verify_handoff, gc, cleanup_zombies, tool_stats,
    tool_help, tool_admin, deep_review. *)

type tool_result = bool * string

type context = {
  config : Coord.config;
  agent_name : string;
}

val schemas : Types.tool_schema list

val looks_like_rss_payload : string -> bool
val parse_bing_rss_items : string -> (string * string * string) list
val parse_searxng_json : string -> (string * string * string) list
val parse_ddg_html : string -> (string * string * string) list
val parse_brave_json : string -> (string * string * string) list
val parse_tavily_json : string -> (string * string * string) list
val parse_exa_json : string -> (string * string * string) list
val parse_bing_search_json : string -> (string * string * string) list
val redact_transport_error_detail : string -> string
val web_search_provider_plan : unit -> string list
val web_search_simulate_for_test :
  query:string ->
  limit:int ->
  (string
   * [ `Error of string
     | `Empty
     | `Hits of (string * string * string) list
     ])
  list ->
  tool_result

val dispatch : context -> name:string -> args:Yojson.Safe.t -> tool_result option

val tool_inventory_json :
  context -> include_hidden:bool -> include_deprecated:bool -> Yojson.Safe.t
