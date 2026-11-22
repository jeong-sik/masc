(** Contract 4 — Fleet Candle Ledger ([GET /api/v1/candle/ledger]) &
    Categorized TOML Config Schema/Patch API
    ([GET /api/v1/config/schema], [POST /api/v1/config/patch]).

    - Reuses {!Candle_ledger}, {!Candle_balance}, {!Candle_config},
      {!Candle_event}, {!Keeper_runtime_setting_registry},
      {!Keeper_runtime_config}, {!Keeper_types_profile}, {!Toml_line_editor},
      {!Secret_patterns}, and {!Fs_compat.save_file_atomic}.
    - Zero raw secrets are ever serialized on schema reads or patch diffs.
    - Comment-preserving line edits produce a unified diff for [dry_run: true]
      and snapshot backups returning [snapshot_id] on atomic [dry_run: false]
      commits. *)

type config_target =
  | Target_runtime
  | Target_keeper of string
  | Target_keeper_create

type config_category =
  | Cat_runtime_providers
  | Cat_routing_failover
  | Cat_keepers_autonomy
  | Cat_sandbox_infra
  | Cat_memory_knowledge
  | Cat_economy_connectors
  | Cat_observability_ops

val all_config_categories : config_category list
val config_category_to_string : config_category -> string

type provenance =
  | Prov_default
  | Prov_global
  | Prov_project
  | Prov_keeper
  | Prov_env_override

val provenance_to_string : provenance -> string

type reload_scope =
  | Hot_reload
  | Next_turn
  | Restart_required

val reload_scope_to_string : reload_scope -> string

val classify_runtime_key_reload_scope :
  ?known_provider_ids:(string, unit) Hashtbl.t ->
  string ->
  reload_scope
(** Classify a non-Registry [runtime.toml] key as {!Hot_reload} (provider,
    model, lane, binding, routing, and timeout/retry settings applied via
    {!Server_runtime_config_broadcast}) vs {!Restart_required} (bind, port,
    storage, listener, and domain/worker pool settings). *)

val is_secret_key : string -> bool
(** True for keys whose raw values must always be masked (API keys, auth
    headers, cookies, sessions, HMAC/signing keys, tokens, passwords, secrets,
    private keys). *)

val redact_value_secrets : string -> string
(** Redact secret patterns, URL userinfo ([user:pass@]), and sensitive URL
    query parameters ([?key=], [?token=], [?api_key=], etc.) from a scalar
    value or TOML line. *)

val redact_diff_line : string -> string
(** Redact any sensitive assignment value or secret-shaped token in a diff line. *)

val compute_unified_diff :
  before_label:string ->
  after_label:string ->
  before:string ->
  after:string ->
  string * Yojson.Safe.t list
(** Deterministic, secret-redacted line-level unified diff returning
    [(unified_diff_text, structured_hunks_json)]. *)

val parse_target :
  target:string option ->
  keeper:string option ->
  (config_target, string * string) result
(** Strict parser accepting [runtime], [keeper:<name>], [keeper] + [keeper=<name>],
    or [keeper_create]. *)

val candle_ledger_json :
  ?now:float ->
  ?limit:int ->
  ?keeper:string ->
  base_path:string ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Projection for [GET /api/v1/candle/ledger]. *)

val config_schema_json :
  ?now:float ->
  base_path:string ->
  target:config_target ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Projection for [GET /api/v1/config/schema]. *)

val config_patch_json :
  ?now:float ->
  config:Workspace.config ->
  actor:string ->
  body_str:string ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Handler for [POST /api/v1/config/patch]. Supports [dry_run: true] unified
    diff preview and [dry_run: false] atomic commit via
    {!Fs_compat.save_file_atomic} with backup [snapshot_id]. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
(** Register [/api/v1/candle/ledger], [/api/v1/config/schema], and
    [/api/v1/config/patch]. *)
