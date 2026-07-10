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
val keeper_suffix_secrets : string
val keeper_suffix_boot : string
val keeper_suffix_shutdown : string
val keeper_suffix_reset : string
val keeper_suffix_clear : string
val keeper_suffix_checkpoints : string
val keeper_suffix_runtime_trace : string
val keeper_suffix_directive : string
val keeper_suffix_catchup_judge : string

(** {1 Dashboard cache keys} *)

val cache_key_string_segment : string -> string
(** Length-prefixed cache key segment so delimiter characters in the value
    cannot create key collisions. *)

val cache_key_string_opt_segment : string option -> string
(** [None] and [Some ""] produce distinct segments. *)

val keeper_config_cache_key : Workspace.config -> string -> string
(** Cache key for [/api/v1/keepers/<name>/config]. Used by both read and
    invalidation paths. *)

val keeper_composite_cache_key : Workspace.config -> string -> string
(** Cache key for [/api/v1/keepers/<name>/composite]. *)

val keeper_runtime_trace_cache_key :
  Workspace.config ->
  string ->
  ?trace_id:string ->
  ?turn_id:int ->
  limit:int ->
  unit ->
  string
(** Cache key for [/api/v1/keepers/<name>/runtime-trace]. Optional query
    fields are tagged so absent values cannot collide with literal payloads. *)

type keeper_post_route_kind =
  | Keeper_post_tools
  | Keeper_post_config
  | Keeper_post_secrets
  | Keeper_post_boot
  | Keeper_post_shutdown
  | Keeper_post_reset
  | Keeper_post_clear
  | Keeper_post_checkpoints
  | Keeper_post_directive
  | Keeper_post_catchup_judge
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

(** {1 Keeper name validation} *)

val is_valid_keeper_name : String.t -> bool
(** [true] when [name] passes the shared keeper-name character class. *)

val extract_keeper_name_for_post : string -> string -> string
(** [extract_keeper_name_for_post path suffix]: variant used by the
    POST dispatcher. *)

val manifest_row_matches :
  ?turn_id:int ->
  string ->
  string ->
    Keeper_runtime_manifest.t ->
  bool
(** Pure: true when the runtime-manifest row matches the given keeper_name +
    trace_id (and optionally turn_id). *)

val unique_present_paths : string option list -> string list
(** Pure: dedupe + trim filtered string list. *)

val take_last : int -> 'a list -> 'a list
(** [take_last n xs] returns the last [n] elements of [xs]. *)

val provider_attempt_row_json :
  Keeper_runtime_manifest.t -> Yojson.Safe.t
(** Pure: provider-attempt manifest row → JSON record. *)

val string_contains_substring : string -> string -> bool
(** Pure: naive substring presence test. *)

val runtime_trace_keeps_provider_attempt_provenance_key : string -> bool
(** Pure: allowlist for provider/model-related decision keys in
    runtime-trace responses. *)

val runtime_trace_redacts_provider_model_key : string -> bool
(** Pure: redact-by-substring policy for the runtime-trace public surface. *)

val runtime_trace_public_json : Yojson.Safe.t -> Yojson.Safe.t
(** Pure: recursively redact provider/model identity fields from runtime
    trace JSON before returning to external dashboards. *)

(** {1 Tool-call JSON inspectors}

    Pure helpers for extracting fields out of trajectory tool-call JSON
    records. Used by the runtime-lens response builders. *)

val tool_call_output_text_opt : Yojson.Safe.t -> string option
val parse_tool_output_json_opt : Yojson.Safe.t -> Yojson.Safe.t option
val tool_call_runtime_contract : Yojson.Safe.t -> Yojson.Safe.t

val tool_call_matches_trace :
  ?turn_id:int ->
  keeper_name:string ->
  trace_id:string ->
  Yojson.Safe.t ->
  bool

(** {1 Option list + string utilities} *)

val first_string_opt : string option list -> string option
val first_int_opt : int option list -> int option
val string_has_prefix : prefix:string -> string -> bool

(** {1 Claim tool-call summary} *)

val claim_status_of_output : Yojson.Safe.t -> string
(** Pure: classify a keeper_task_claim tool-call output JSON. *)

val claim_scope_summary_absent : Yojson.Safe.t
(** Pure constant: JSON record returned when no matching claim was
    observed. *)

val internal_history_json_to_trajectory_line :
  Yojson.Safe.t -> Trajectory.trajectory_line option
(** Pure: decode one [internal_assistant] history JSON line into a
    [Trajectory.Thinking] record. Returns [None] when the line is missing
    required fields or originates from a non-internal source. *)

val runtime_manifest_public_json :
  Keeper_runtime_manifest.t -> Yojson.Safe.t
(** Pure: convert a manifest row to its public JSON, with provider/model
    identity redaction applied. *)
