(** Tool_misc — miscellaneous MASC tool handlers.

    Dispatches: transport_status, websocket_discovery, webrtc,
    dashboard, verify_handoff, gc, cleanup_zombies, tool_stats,
    tool_help, tool_admin, keeper_tool_catalog, deep_review. *)

type result = bool * string

type context = {
  config : Room.config;
  agent_name : string;
}

val schemas : Types.tool_schema list

val looks_like_rss_payload : string -> bool
val parse_bing_rss_items : string -> (string * string * string) list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option

val tool_inventory_json :
  context -> include_hidden:bool -> include_deprecated:bool -> Yojson.Safe.t
