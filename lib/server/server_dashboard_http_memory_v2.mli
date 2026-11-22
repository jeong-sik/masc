(** Contract 3 — World Memory & Temporal Memory Diff HTTP API
    ([GET /api/v1/memory/world] and [GET /api/v1/memory/diff]).

    Projects {!Workspace_memory_ledger}, {!Workspace_memory_briefing},
    {!Workspace_memory_log}, {!Keeper_memory_os_current},
    {!Keeper_memory_os_events}, and {!Keeper_memory_writer_health} without
    duplicating store formats or inference logic. *)

type diff_scope =
  | Scope_world
  | Scope_keeper of string

type diff_window =
  | Window_24h
  | Window_7d
  | Window_30d

type diff_range =
  | Range_window of diff_window
  | Range_revs of
      { from_rev : int
      ; to_rev : int option
      }

type retrieval_heat =
  | Heat_hot
  | Heat_warm
  | Heat_cold
  | Heat_never

val retrieval_heat_to_string : retrieval_heat -> string

val classify_retrieval_heat :
  now:float -> retrieved_count:int -> last_retrieved_at:float option -> retrieval_heat
(** Pure retrieval heat tier derived from actual {!Keeper_memory_os_events}
    timestamps and counts. *)

val parse_diff_query :
  scope:string option ->
  keeper:string option ->
  window:string option ->
  from_rev:string option ->
  to_rev:string option ->
  (diff_scope * diff_range, string * string) result
(** Strict query parser returning [Error (field, message)] for missing, unknown,
    or conflicting query parameters. *)

val world_json :
  ?now:float ->
  config:Workspace.config ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Projection for [GET /api/v1/memory/world]. *)

val diff_json :
  ?now:float ->
  config:Workspace.config ->
  scope:diff_scope ->
  range:diff_range ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Projection for [GET /api/v1/memory/diff]. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
(** Register [/api/v1/memory/world] and [/api/v1/memory/diff]. *)
