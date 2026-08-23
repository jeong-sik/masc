(** Single-keeper status detail handler.

    Owns the [keeper_status] tool dispatch; this module handles the
    per-keeper detail view.

    Selective .mli — internal helpers ([latest_metrics_json],
    [model_observability_json], dispatch helpers, etc.) stay private. *)

type tool_result = Keeper_types_profile.tool_result

(** Sort order for tail-window projections (metrics / trajectory). *)
type tail_order = Keeper_status_options_defaults.tail_order =
  | Oldest_first
  | Newest_first

(** Whether a keeper with this (possibly alias-spelled) name exists, using
    the same candidate spellings and effective-meta read as the status
    resolver. [Ok false] covers unknown and invalid names; [Error] is a
    store read failure. *)
val keeper_exists_config :
  config:Workspace.config -> string -> (bool, string) result

val tail_order_to_string : tail_order -> string

(** Every variant in [tail_order]; used by the [Keeper_schema]
    enum mirror. *)
val all_tail_orders : tail_order list

(** Variant labels used in tool-input enum schemas. *)
val valid_tail_order_strings : string list

(** [keeper_status] tool handler. Builds a fresh observation so time-derived,
    file-backed, registry, queue, and sandbox fields cannot be frozen behind
    an incomplete cache identity. *)
val handle_keeper_status :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result

(** RFC-0182 §3.1 — ctx-free entry point for keeper_dispatch_ref path. *)
val handle_keeper_status_config :
  config:Workspace.config -> agent_name:string -> Yojson.Safe.t -> tool_result
