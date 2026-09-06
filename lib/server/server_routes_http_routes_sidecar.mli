(** Server Routes — sidecar HTTP API.

    Implements [/api/sidecar/<id>/...] for the connector sidecars that run
    as their own process — telegram alone now; Discord, Slack and iMessage moved
    in-process (RFC-0203 Phase 3, RFC-0317) and the dashboard hides these
    controls for them.  Serves status, start/stop, log tail, GET/PUT TOML
    config, and schema introspection.

    The desired-state pair (desired_record / attempt_record, persisted as
    JSON under [.masc/sidecars]) is reconciled once per start request, in
    [handle_start].  Nothing reconciles on a timer: [add_routes] takes no
    switch or clock, so a sidecar that dies on its own stays down until an
    operator asks for it again. *)

module Http = Http_server_eio
(** Local alias for the Eio HTTP server module. *)

(** {1 Sidecar id validation} *)

val known_ids : string list
(** Hard-coded sidecar id allowlist (["telegram"]).  Path
    routing rejects anything not in this list. *)

val validate_name : string option -> (string, string) result
(** [Ok id] when [name] passes [known_ids] gating. *)

(** {1 String helpers} *)

(** {1 Base-path / project root resolution} *)

val runtime_base_path : ?base_path:string -> unit -> string
(** Effective [base_path] for runtime path resolution. Raises when no
    explicit or env-derived base path is available. *)

val runtime_base_path_result : ?base_path:string -> unit -> (string, string) result
(** Effective [base_path] for runtime path resolution. The request-scoped
    [base_path] wins; otherwise the resolver's env-derived base path wins. *)

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

(** {1 Sidecar status config (env / TOML lookup)} *)

type sidecar_status_config = {
  env_names : string list;
  toml_keys : string list;
  stale_after_env_name : string;
}
(** Where a sidecar's status file may be configured, and the variable
    naming the age at which its heartbeat stops counting as alive. *)

val status_file :
  ?sidecar_root:string ->
  ?project_root:string ->
  ?sidecar_dir:string -> base_path:string -> string -> string
(** Resolve the canonical [status.json] path for a sidecar. *)

val today_log_file :
  ?sidecar_root:string ->
  ?project_root:string -> base_path:string -> string -> string
(** Resolve the per-day log file path. *)

val runtime_sidecar_dir_result :
  ?base_path:string -> string -> (string, string) result

type sidecar_start_plan = {
  argv : string list;
  env : string array;
}
(** argv/env bundle used by the start route to launch [script] under
    [base_path] without shell interpolation. *)

val sidecar_start_plan : base_path:string -> script:string -> sidecar_start_plan
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
  attempt : Attempt_state.t;
  operator_next_action : string;
}
(** Persisted reconciliation attempt record (one per generation).
    [attempt] is the shared {!Attempt_state.t} SSOT; ISO timestamps and
    string result tokens are only used at the JSON wire boundary. *)

(** Decode failure for a persisted desired or attempt record. *)
type record_decode_error =
  | Record_not_object of string
  | Record_invalid_field of {
      field : string;
      expected : string;
      actual : string;
    }
  | Record_unknown_value of {
      field : string;
      value : string;
    }
  | Record_invalid_timestamp of {
      field : string;
      value : string;
    }

val record_decode_error_to_string : record_decode_error -> string

val desired_state_to_string : desired_state -> string
val reconcile_result_to_string : reconcile_result -> string

val attempt_record_of_json_result :
  Yojson.Safe.t -> (attempt_record, record_decode_error) result
val desired_record_of_json_result :
  Yojson.Safe.t -> (desired_record, record_decode_error) result
val sidecar_desired_path : base_path:string -> string -> string
val sidecar_attempt_path : base_path:string -> string -> string

(** [Ok None] when the file is absent; [Error] when it exists but cannot be
    read, is not JSON, or does not decode. *)
val read_desired_record_result :
  base_path:string -> string -> (desired_record option, string) result
val read_attempt_record_result :
  base_path:string -> string -> (attempt_record option, string) result
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

(** Project [status.json] into the reconciler's observed-state. *)

(** Backoff duration between reconcile attempts. *)

val retry_backoff_active : now:string -> attempt_record -> bool
(** [true] when [now] is still inside the backoff window for the
    last attempt. [now] is parsed at the boundary; the deadline comparison
    uses {!Attempt_state.is_backoff_active}. *)

(** Compute the next [attempt_record] given the previous one and the
    reconciler decision context. *)

val reconcile_desired_once :
  ?now:string ->
  ?next_retry_at:string ->
  ?previous_attempt:attempt_record ->
  ?write_attempt:(attempt_record -> (unit, 'a) result) ->
  current_generation:int ->
  observed_state:observed_state ->
  start_process:(unit -> 'b) -> desired_record -> reconcile_result
(** Single reconciliation tick: compares [desired_record] vs
    [observed_state], honours backoff, and either invokes
    [start_process] or returns a [Reconcile_noop] reason. *)

(** Combined lifecycle JSON: status fields + desired/attempt projection. *)

(** Append a [(key, value)] pair to a JSON assoc. *)

val clamp_lines : int option -> int
(** Clamp the [?lines] query parameter to the supported tail range. *)

(** {1 HTTP responders} *)

val read_status_json : base_path:string -> string -> Yojson.Safe.t


(** {1 Schema cache} *)

val reset_schema_cache : unit -> unit
val python_argv_for : string -> string list
val fetch_schema : ?base_path:string -> string -> (string, string) result

(** {1 TOML rendering} *)

type toml_value =
  | Tstring of string
  | Tint of int
  | Tfloat of float
  | Tbool of bool

val escape_toml_string : string -> string
val render_value : toml_value -> string
val render_toml : (string * toml_value) list -> string

(** {1 Schema-driven coercion} *)

type declared_type = [ `Boolean | `Integer | `Number | `String ]
(** Subset of JSON-schema types accepted on PUT. *)

val parse_declared_type : Yojson__Safe.t -> declared_type option
val coerce_value : declared_type -> string -> (toml_value, string) result
(** Coerce a string value to [declared_type] or return a parse error. *)

val parse_body_pairs : string -> ((string * string) list, string) result

(** {1 Config / schema / lifecycle handlers} *)

val add_routes :
  sw:'a -> clock:'b -> Http.Router.t -> Http.Router.t
(** Compose every sidecar route on top of [routes].  Called from the
    HTTP routing assembly. *)
