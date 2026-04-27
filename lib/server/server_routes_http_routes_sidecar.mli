(** Server Routes — sidecar HTTP API.

    Implements [/api/sidecar/<id>/...] for the Discord / cron / connector
    sidecars: status, start/stop, log tail, GET/PUT TOML config, schema
    introspection, and the desired-state reconciler that drives the
    sidecar restart loop.  Mostly path-resolution + filesystem helpers
    plus a small declarative-state pair (desired_record / attempt_record)
    persisted as JSON under [.masc/sidecars]. *)

module Http = Http_server_eio
(** Local alias for the Eio HTTP server module. *)

(** {1 Sidecar id validation} *)

val known_ids : string list
(** Hard-coded sidecar id allowlist (e.g. ["discord"], ["cron"]).  Path
    routing rejects anything not in this list. *)

val validate_name : string option -> (string, string) result
(** [Ok id] when [name] passes [known_ids] gating. *)

val parse_name : Httpun.Request.t -> (string, string) result
(** Parse + validate the sidecar id from the request path. *)

(** {1 String helpers} *)

val starts_with : prefix:string -> string -> bool
val trim_opt : string option -> string option

(** {1 Base-path / project root resolution} *)

val runtime_base_path : ?base_path:string -> unit -> string
(** Effective [base_path] for runtime path resolution.  Defaults to
    the configured server base when not provided. *)

val request_base_path : Mcp_server.server_state -> string
(** Base path bound to the server state for the current process. *)

val dir_exists : string -> bool
(** [Sys.file_exists]+[is_directory] guarded against EACCES. *)

val dedupe_keep_order : 'a list -> 'a list
(** Keep first occurrence of each value. *)

val project_root_from_executable : unit -> string option
(** Resolve the masc-mcp project root from [Sys.executable_name];
    [None] for installed binaries that live outside a checkout. *)

val sidecar_root : unit -> string option
(** [SIDECAR_ROOT] env override, normalised to absolute path. *)

val sidecar_root_candidates :
  ?sidecar_root:'a -> ?project_root:'a -> base_path:'a -> unit -> 'a list
(** Ordered candidates for the sidecar root (env > project > base_path). *)

val sidecar_dir_under : string -> string -> string
(** [sidecar_dir_under root id] computes the conventional
    [<root>/sidecars/<id>] path. *)

val resolve_existing_sidecar_dir :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string option
(** Find the first existing sidecar directory across the candidate
    roots; [None] when nothing matches. *)

val missing_sidecar_dir_message :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string
(** Render the user-visible "no sidecar found" error message that
    enumerates each path that was tried. *)

(** {1 Date / status path helpers} *)

val today_yyyymmdd : unit -> string
(** Local-timezone [yyyymmdd] used in log file names. *)

val legacy_status_rel : string -> string
(** Legacy relative path of the per-sidecar status JSON. *)

(** {1 Sidecar status config (env / TOML lookup)} *)

type sidecar_status_config = {
  env_names : string list;
  toml_keys : string list;
}
(** Names to consult when resolving a sidecar's "is enabled" flag. *)

val sidecar_status_config : string -> sidecar_status_config
(** Per-sidecar [sidecar_status_config] (Discord checks
    [DISCORD_BOT_TOKEN] etc.). *)

val read_file : string -> string
(** Read whole file; returns empty string when the file is missing. *)

val strip_matching_quotes : string -> string
(** Strip a single matching pair of single or double quotes from [s]. *)

val parse_env_assignment : string -> (string * string) option
(** Parse [KEY=VALUE] from a [.env]-style line; [None] for comments/
    blanks. *)

val env_file_lookup : string -> string list -> string option
(** Find the value for any of [keys] in [path]. *)

val toml_lookup : string -> string list -> string option
(** Crude top-level TOML key lookup that doesn't require a full
    parser dep on the request path. *)

val resolve_relative_path : roots:string list -> string -> string list
(** Expand [rel] against each root, returning every existing match. *)

val first_existing_or_first : string list -> string option
(** First existing path, or [None]; ordering preserved. *)

val runtime_toml_path : base_path:string -> string -> string
(** Path of the sidecar's runtime TOML config under [base_path]. *)

val status_file_candidates :
  ?sidecar_root:string ->
  ?project_root:string ->
  ?sidecar_dir:string -> base_path:string -> string -> string list
val status_file :
  ?sidecar_root:string ->
  ?project_root:string ->
  ?sidecar_dir:string -> base_path:string -> string -> string
(** Resolve the canonical [status.json] path for a sidecar. *)

val log_file_candidates :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string list
val today_log_file :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string
(** Resolve the per-day log file path. *)

val runtime_sidecar_dir_result :
  ?base_path:string -> string -> (string, string) result
val runtime_sidecar_script_result :
  ?base_path:string -> string -> (string, string) result
(** Locate the sidecar directory and start script for runtime
    operations; [Error msg] when missing, with a path enumeration. *)

val sidecar_start_shell_command : base_path:string -> script:string -> string
(** Render the shell command used by the start route to launch
    [script] under [base_path]. *)

(** {1 Declarative state machine} *)

type desired_state = Desired_running | Desired_stopped
(** Operator-set target state. *)

type desired_record = {
  connector_id : string;
  desired_state : desired_state;
  generation : int;
  updated_by : string;
  updated_at : string;
}
(** Persisted desired-state record. *)

type observed_state = Observed_available | Observed_unavailable
(** Reconciler input derived from the sidecar's [status.json]. *)

type reconcile_result = Reconcile_started | Reconcile_noop of string
(** Reconciler decision: either a start was attempted, or no-op with
    a reason. *)

type attempt_record = {
  connector_id : string;
  generation : int;
  attempt_id : string;
  attempt_number : int;
  last_attempt_result : string;
  next_retry_at : string option;
  operator_next_action : string;
  updated_at : string;
}
(** Persisted reconciliation attempt record (one per generation). *)

val desired_state_to_string : desired_state -> string
val desired_state_of_string : string -> desired_state option
val observed_state_to_string : observed_state -> string
val reconcile_result_to_string : reconcile_result -> string

val attempt_record_json :
  attempt_record ->
  [> `Assoc of (string * [> `Int of int | `Null | `String of string ]) list ]
val attempt_record_of_json :
  [> `Assoc of (string * [> `Int of int | `Null | `String of string ]) list ] ->
  attempt_record option
val desired_record_json :
  desired_record ->
  [> `Assoc of (string * [> `Int of int | `String of string ]) list ]
val desired_record_of_json :
  [> `Assoc of (string * [> `Int of int | `String of string ]) list ] ->
  desired_record option

val sidecar_desired_path : base_path:string -> string -> string
val sidecar_attempt_path : base_path:string -> string -> string
val read_desired_record : base_path:string -> string -> desired_record option
val read_attempt_record : base_path:string -> string -> attempt_record option

val isoish_now : unit -> string
(** ISO-8601-ish timestamp used for [updated_at]. *)

val isoish_at : float -> string
(** ISO-8601-ish timestamp from a Unix epoch float. *)

val ensure_parent_dir : string -> unit
(** Create the parent directory of [path] if missing. *)

val atomic_write_file : path:string -> string -> (unit, string) result
(** Tempfile + rename atomic write. *)

val write_desired_record :
  ?updated_at:string ->
  base_path:string ->
  id:string ->
  updated_by:string -> desired_state -> (desired_record, string) result
val write_attempt_record :
  base_path:string -> id:string -> attempt_record -> (unit, string) result

val observed_state_of_status_json :
  [> `Assoc of (string * [> `Bool of bool ]) list ] -> observed_state
(** Project [status.json] into the reconciler's observed-state. *)

val retry_backoff_seconds : unit -> float
(** Backoff duration between reconcile attempts. *)

val retry_backoff_active : now:string -> attempt_record -> bool
(** [true] when [now] is still inside the backoff window for the
    last attempt. *)

val next_attempt_record :
  now:string ->
  next_retry_at:string ->
  attempt_record option -> desired_record -> attempt_record
(** Compute the next [attempt_record] given the previous one and the
    reconciler decision context. *)

val reconcile_desired_once :
  ?now:string ->
  ?next_retry_at:string ->
  ?previous_attempt:attempt_record ->
  ?write_attempt:(attempt_record -> (unit, 'a) result) ->
  current_generation:int ->
  observed_state:observed_state ->
  start_shell:(unit -> 'b) -> desired_record -> reconcile_result
(** Single reconciliation tick: compares [desired_record] vs
    [observed_state], honours backoff, and either invokes
    [start_shell] or returns a [Reconcile_noop] reason. *)

val reconcile_preview :
  ?now:string ->
  ?previous_attempt:attempt_record ->
  desired_record -> observed_state -> string
(** Dry-run preview suitable for a dashboard tooltip. *)

val attempt_fields :
  attempt_record option -> (string * [> `Null | `String of string ]) list
(** Render attempt fields as JSON-friendly assoc list (possibly empty). *)

val lifecycle_json :
  base_path:string ->
  string ->
  [> `Assoc of (string * [> `Bool of bool ]) list ] ->
  [> `Assoc of (string * [> `Int of int | `Null | `String of string ]) list ]
(** Combined lifecycle JSON: status fields + desired/attempt projection. *)

val append_assoc : 'a -> 'b -> ([> `Assoc of ('a * 'b) list ] as 'c) -> 'c
(** Append a [(key, value)] pair to a JSON assoc. *)

val clamp_lines : int option -> int
(** Clamp the [?lines] query parameter to the supported tail range. *)

(** {1 HTTP responders} *)

val respond_json :
  Httpun.Request.t ->
  Httpun.Reqd.t -> status:Httpun.Status.t -> Yojson.Safe.t -> unit
val bad_request : Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
val read_status_json :
  base_path:string -> string -> [> `Assoc of (string * Yojson.Safe.t) list ]

val handle_status :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_stop :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_logs :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit

(** {1 Schema cache} *)

val schema_cache : (string, string) Hashtbl.t
val reset_schema_cache : unit -> unit
val python_argv_for : string -> string list
val fetch_schema : ?base_path:string -> string -> (string, string) result

(** {1 TOML rendering} *)

type toml_value =
  | Tstring of string
  | Tint of int
  | Tfloat of float
  | Tbool of bool

val max_value_bytes : int
(** Cap on individual TOML value sizes accepted via PUT. *)

val escape_toml_string : string -> string
val render_value : toml_value -> string
val render_toml : (string * toml_value) list -> string

(** {1 Schema-driven coercion} *)

type declared_type = [ `Boolean | `Integer | `Number | `String ]
(** Subset of JSON-schema types accepted on PUT. *)

val parse_declared_type : Yojson__Safe.t -> declared_type option
val schema_field_types :
  ?base_path:string -> string -> (string * declared_type) list
val coerce_value : declared_type -> string -> (toml_value, string) result
(** Coerce a string value to [declared_type] or return a parse error. *)

val config_toml_path : base_path:string -> string -> string
val parse_body_pairs : string -> ((string * string) list, string) result

(** {1 Config / schema / lifecycle handlers} *)

val handle_get_config :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_put_config :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_schema :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_start :
  Mcp_server.server_state ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit

val add_routes :
  sw:'a -> clock:'b -> Http.Router.route list -> Http.Router.route list
(** Compose every sidecar route on top of [routes].  Called from the
    HTTP routing assembly. *)
