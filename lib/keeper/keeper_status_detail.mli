(** Single-keeper status detail handler.

    Owns the [keeper_status] tool dispatch plus the response cache
    that keeps the dashboard latency manageable. The list /
    trajectory / eval handlers are in [Keeper_status]; this module
    only handles the per-keeper detail view.

    Selective .mli — internal helpers (cache hashtable + mutex,
    [model_observability_json], the [resolve_status_target]
    dispatch helpers, etc.) stay private. *)

type tool_result = Keeper_types_profile.tool_result

(** Sort order for tail-window projections (metrics / trajectory). *)
type tail_order =
  | Oldest_first
  | Newest_first

(** Parse the [tail_order] argument from a tool-call JSON.
    Defaults to [Oldest_first] for unknown / missing values. *)
val tail_order_of_args : Yojson.Safe.t -> tail_order

val tail_order_to_string : tail_order -> string

(** Every variant in [tail_order]; used by the [Keeper_schema]
    enum mirror. *)
val all_tail_orders : tail_order list

(** Variant labels used in tool-input enum schemas. *)
val valid_tail_order_strings : string list

(** Apply [tail_order] to a list of items. Identity for
    [Oldest_first], [List.rev] for [Newest_first]. *)
val apply_tail_order : tail_order -> 'a list -> 'a list

(** Drop the cache entry for a single keeper; called from any
    state-change path that invalidates the cached snapshot. *)
val invalidate_status_cache_for : string -> unit

(** Drop the entire status cache; called on global state changes
    (boot, mass reload). *)
val invalidate_status_cache_all : unit -> unit

(** [keeper_status] tool handler. Reads from the response cache
    when the keeper's [updated_at] + args hash is unchanged;
    otherwise rebuilds the snapshot and refreshes the cache. *)
val handle_keeper_status :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result

(** RFC-0182 §3.1 — ctx-free entry point for keeper_dispatch_ref path. *)
val handle_keeper_status_config :
  config:Workspace.config -> agent_name:string -> Yojson.Safe.t -> tool_result
