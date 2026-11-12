(** Server_dashboard_http_keeper_api_types — routing types + shared helpers
    extracted from Server_dashboard_http_keeper_api (3136 LoC godfile).

    Holds the [keeper_post_route_kind] ADT + path classification helpers
    + URL prefix/suffix string constants + the error envelope
    ([error_json], [respond_error]) that the dashboard handlers share.
    State-touching HTTP handlers remain in
    Server_dashboard_http_keeper_api. Re-included by that module
    so existing callers continue to use
    [Server_dashboard_http_keeper_api.classify_keeper_post_route] etc.
    unchanged. *)

(** Path prefix shared by all keeper API endpoints. *)
val keeper_api_prefix : string

(** Per-route URL suffixes for the keeper API. *)
val keeper_suffix_config : string
val keeper_suffix_secrets : string
val keeper_suffix_github_identity : string
val keeper_suffix_board_attention_quarantines : string
(** [GET /api/v1/keepers/<name>/board-attention/quarantines]: that Keeper's
    rows of the Board-attention quarantine inventory, the same rows the
    operator snapshot lists for the fleet. *)
val keeper_suffix_github_login : string
val keeper_suffix_github_token : string

val keeper_suffix_oauth_login : string

val keeper_suffix_identity_refresh : string
val keeper_suffix_identity_switch : string
(** Ask an attached service again what tools it has. An operator action
    rather than a timer: a stale catalog is visible and fixable, while a
    timer is a network call nobody asked for. *)
(** Attaching a Keeper to a declared work service. Beside github-login
    because it is the same act -- an operator granting one Keeper the right
    to act somewhere -- reached a different way. *)
val keeper_suffix_boot : string
val keeper_suffix_up : string
val keeper_suffix_shutdown : string
val keeper_suffix_reset : string
val keeper_suffix_clear : string
val keeper_suffix_checkpoints : string
val keeper_suffix_provider_input : string
val keeper_suffix_provider_input_part : string
val keeper_suffix_provider_input_continuity : string
val keeper_suffix_runtime_trace : string
val keeper_suffix_directive : string
val keeper_suffix_paused_work : string
val keeper_suffix_fusion : string
val keeper_suffix_operator_note : string

val keeper_suffix_file_changes : string
val keeper_suffix_working_context : string
(** [GET /api/v1/keepers/<name>/working-context] — the exact derived context
    snapshot and its stored-byte SHA-256 for Admin cleanup planning. *)
(** [GET /api/v1/keepers/<name>/file-changes] — the files this keeper wrote,
    read back out of the tool-call log. *)
(** {1 Dashboard cache keys} *)

val cache_key_string_segment : string -> string
(** Length-prefixed cache key segment so delimiter characters in the value
    cannot create key collisions. *)

val keeper_config_cache_key : Workspace.config -> string -> string
(** Cache key for [/api/v1/keepers/<name>/config]. Used by both read and
    invalidation paths. *)

val keeper_composite_cache_key : base_path:string -> string -> string
(** Cache key for [/api/v1/keepers/<name>/composite]. *)

val fleet_composite_cache_key : base_path:string -> string
(** Cache key for the fleet composite envelope of one workspace. *)

val invalidate_workspace_keeper_composites : base_path:string -> unit
(** Retire the roster's fleet envelope and every Keeper selection after a
    membership change. Individual row changes can invalidate one Keeper. *)

val invalidate_keeper_composite_cache : base_path:string -> name:string -> unit
(** Drop the Keeper's composite, so the next read of
    [/api/v1/keepers/<name>/composite] computes it from the registry. *)

val invalidate_keeper_composite_caches : base_path:string -> name:string -> unit
(** {!invalidate_keeper_composite_cache} and the workspace's fleet composite,
    for a change to the Keeper's configuration or secrets. *)

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

val invalidate_keeper_runtime_traces : base_path:string -> name:string -> unit
(** Retire all trace/turn/limit selections for this exact workspace and
    Keeper, including any computation that began before the committed input. *)

type keeper_board_attention_quarantine_route =
  { keeper_name : string
  ; partition_id : string
  }

type keeper_post_route_kind =
  | Keeper_post_config
  | Keeper_post_secrets
  | Keeper_post_github_login
  | Keeper_post_github_token
  | Keeper_post_oauth_login
  | Keeper_post_identity_refresh
  | Keeper_post_identity_switch
  | Keeper_post_boot
  | Keeper_post_up
  | Keeper_post_shutdown
  | Keeper_post_reset
  | Keeper_post_clear
  | Keeper_post_checkpoints
  | Keeper_post_directive
  | Keeper_post_paused_work
  | Keeper_post_fusion
  | Keeper_post_operator_note
  | Keeper_post_board_attention_quarantine_recovery of
      keeper_board_attention_quarantine_route
  | Keeper_post_unknown
(** Sub-route kind for a [POST /api/v1/keepers/<name>/...] path. *)

val classify_keeper_post_route : string -> keeper_post_route_kind
(** Map a request path to its [keeper_post_route_kind]. *)

val extract_keeper_name_for_suffix : string -> string -> string
(** [extract_keeper_name_for_suffix path suffix] returns the keeper name
    from a path of shape [/api/v1/keepers/<name>/<suffix>]. A path of any
    other shape, including one with no name segment between the prefix and
    [suffix], or an invalid name gives [""]. It does not raise. *)

val extract_keeper_name_for_post : string -> string -> string
(** [extract_keeper_name_for_post path suffix]: the POST dispatcher's
    spelling of {!extract_keeper_name_for_suffix}, and the same function --
    the path grammar does not depend on the method. *)

(** {1 Trajectory preview helpers} *)

val trim_to_opt : string -> string option
(** Trim and return [None] if empty. *)

val truncate_text : max_chars:int -> string -> string
(** Truncate [text] to [max_chars] (UTF-8 safe). *)

val preview_of_message : Agent_core.Types.message -> string option
(** A non-system message's text, trimmed and cut for the dashboard list view;
    [None] when it has none. The list shows the latest message that has one. *)

(** {1 Keeper name validation} *)

val is_valid_keeper_name : String.t -> bool
(** [true] when [name] passes {!Keeper_config.validate_name}. *)

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

val runtime_trace_public_json : Yojson.Safe.t -> Yojson.Safe.t
(** Pure: recursively redact provider/model identity fields from runtime
    trace JSON before returning to external dashboards. *)

(** {1 Tool-call JSON inspectors}

    Pure helpers for extracting fields out of trajectory tool-call JSON
    records. Used by the runtime-lens response builders. *)

(** {1 Option list + string utilities} *)

val first_string_opt : string option list -> string option

(** Pure constant: JSON record returned when no matching claim was
    observed. *)

val runtime_manifest_public_json :
  Keeper_runtime_manifest.t -> Yojson.Safe.t
(** Pure: convert a manifest row to its public JSON, with provider/model
    identity redaction applied. *)

(** {1 Error envelope} *)

val error_json : ?ok:bool -> string -> Yojson.Safe.t
(** [error_json ?ok message] builds [`Assoc] with an ["error"] field holding
    [message], prefixed by an ["ok"] boolean field when [ok] is supplied. *)

val respond_error :
  ?status:Httpun.Status.t ->
  ?request:Httpun.Request.t ->
  ?ok:bool ->
  Http_reqd.t ->
  string ->
  unit
(** [respond_error ?status ?request ?ok reqd message] answers [reqd] with
    {!error_json} as the JSON body. [status] defaults to [`Bad_request]. *)
