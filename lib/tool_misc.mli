
(** Tool_misc — miscellaneous MASC tool handlers.

    Dispatches: transport_status, websocket_discovery,
    dashboard, verify_handoff, gc, tool_help, config introspection,
    and web helpers. *)

type tool_result = Tool_result.result
(** Re-exported from {!Tool_result}.  RFC-0062 Phase 4c-2:
    handlers return structured [Tool_result.result] records. *)

type context = {
  config : Workspace.config;
  agent_name : string;
  help_schemas : Masc_domain.tool_schema list;
}

val parse_searxng_json : string -> (string * string * string) list
val parse_brave_json : string -> (string * string * string) list
val parse_brave_llm_context_json : string -> (string * string * string list) list
val parse_ollama_search_json : string -> (string * string * string) list
val parse_tavily_json : string -> (string * string * string) list
val parse_exa_json : string -> (string * string * string) list
val parse_bing_search_json : string -> (string * string * string) list
val redact_transport_error_detail : string -> string
val web_search_provider_error_to_string : Tool_misc_web_search.provider_error -> string
val web_search_provider_plan : unit -> string list
(* The outcome type is referenced by name, never restated inline, so a
   variant added to the named type can never leave a stale copy here. *)
val web_search_simulate_for_test :
  query:string ->
  limit:int ->
  (string * Tool_misc_web_search.simulated_provider_outcome) list ->
  Tool_result.result

val with_web_search_simulation_for_test :
  outcomes:(string * Tool_misc_web_search.simulated_provider_outcome) list ->
  (unit -> 'a) ->
  'a

val with_web_fetch_http_get_for_test :
  (timeout_sec:int ->
   headers:(string * string) list ->
   max_response_bytes:int ->
   string ->
   (int option * string, string) result) ->
  (unit -> 'a) ->
  'a

(** The context carries the exact schema projection visible to the caller. *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.result option

val tool_inventory_json :
  context -> include_hidden:bool -> Yojson.Safe.t

val register_dashboard_handler :
  (tool_name:string ->
   start_time:float ->
   context ->
   Yojson.Safe.t ->
   Tool_result.result) ->
  unit
