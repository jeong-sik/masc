(** Server_dashboard_http_keeper_api_types — pure routing types + helpers
    extracted from Server_dashboard_http_keeper_api (3136 LoC godfile).

    Holds the [keeper_post_route_kind] ADT + path classification helpers
    + URL prefix/suffix string constants. State-touching HTTP handlers
    remain in Server_dashboard_http_keeper_api. Re-included by that module
    so existing callers continue to use
    [Server_dashboard_http_keeper_api.classify_keeper_post_route] etc.
    unchanged. *)

(** Path prefix shared by all keeper API endpoints. *)
val keeper_api_prefix : string

(** Per-route URL suffixes for the keeper API. *)
val keeper_suffix_tools : string
val keeper_suffix_config : string
val keeper_suffix_boot : string
val keeper_suffix_shutdown : string
val keeper_suffix_reset : string
val keeper_suffix_clear : string
val keeper_suffix_checkpoints : string
val keeper_suffix_runtime_trace : string
val keeper_suffix_directive : string
val keeper_suffix_bdi_snapshot : string

type keeper_post_route_kind =
  | Keeper_post_tools
  | Keeper_post_config
  | Keeper_post_boot
  | Keeper_post_shutdown
  | Keeper_post_reset
  | Keeper_post_clear
  | Keeper_post_checkpoints
  | Keeper_post_directive
  | Keeper_post_unknown
(** Sub-route kind for a [POST /api/v1/keepers/<name>/...] path. *)

val classify_keeper_post_route : string -> keeper_post_route_kind
(** Map a request path to its [keeper_post_route_kind]. *)

val keeper_path_ends_with : string -> string -> bool
(** [keeper_path_ends_with path suffix]: helper used by the classifier. *)

val extract_keeper_name_for_suffix : string -> string -> string
(** [extract_keeper_name_for_suffix path suffix] returns the keeper name
    from a path of shape [/api/v1/keepers/<name>/<suffix>]. *)

val is_keeper_checkpoints_get_path : string -> bool
(** [true] for [GET /api/v1/keepers/<name>/checkpoints] paths. *)

val is_keeper_runtime_trace_get_path : string -> bool
(** [true] for [GET /api/v1/keepers/<name>/runtime-trace] paths. *)

(** {1 Trajectory preview helpers} *)

val trim_to_opt : string -> string option
(** Trim and return [None] if empty. *)

val truncate_text : max_chars:int -> string -> string
(** Truncate [text] to [max_chars] (UTF-8 safe). *)

val latest_preview_of_messages :
  Agent_sdk.Types.message list -> string option
(** Latest assistant-text preview suitable for the dashboard list view. *)

val continuity_summary_of_messages :
  Agent_sdk.Types.message list -> string option
(** Latest [STATE]-derived continuity summary in the message history. *)
