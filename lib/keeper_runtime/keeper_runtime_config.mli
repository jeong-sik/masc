(** Keeper_runtime_config — load startup runtime env seeding from
    [<resolved config root>/runtime.toml].

    Per-base-path config for transport liveness, capacity, WebSearch
    provider selection, and other startup-scoped runtime parameters that
    previously lived only in environment variables. Closes the architectural gap
    where tools/Keeper instructions/runtime are per-base-path but selected runtime tuning
    was global.

    Precedence (highest first):
      1. Process env var (caller override, e.g. CI/test)
      2. TOML value from [<resolved config root>/runtime.toml]
      3. Hardcoded default in the owning [Env_config_*] reader.

    The TOML loader runs at server startup, before any module that reads
    these env vars initializes. It stores boot defaults in a process-local
    override table so existing config readers can resolve TOML-backed values
    without mutating the parent environment. This file is startup-only today;
    there is no hot-reload path.

    @since 0.7.1 *)

(** Load TOML from [<resolved config root>/runtime.toml] and
    record any overrides in the process-local boot override store.

    The resolved config root honors [MASC_CONFIG_DIR] when set; otherwise it
    uses [<base_path>/.masc/config].

    Process-level env vars set by the caller take precedence — the TOML
    value is only applied when the env var is unset. This preserves the
    CI/test workflow of overriding via env.

    Returns [Ok num_overrides] (count of TOML keys actually applied,
    excluding those preempted by existing env vars), or [Error msg] on
    parse failure.  Missing file is not an error: returns [Ok 0]. *)
(** Why [load_and_apply] failed. The bootstrap counter labels itself from this
    rather than re-reading the rendered message, so a new constructor forces a
    label rather than silently counting nothing. *)
type load_failure_kind =
  | Read
  | Parse
  | Validate

type load_failure =
  { kind : load_failure_kind
  ; message : string
  }

val load_failure_kind_label : load_failure_kind -> string
val all_load_failure_kinds : load_failure_kind list
val load_failure_kind_labels : string list

val load_failure_to_string : load_failure -> string
(** Renders as before: "read <path>: <detail>", "parse …", "validate …". *)

val load_and_apply : base_path:string -> (int, load_failure) result

(** Read the raw TOML value for [env_name] from the shadow registry.
    Returns [None] when the key was absent from [runtime.toml]
    or the file did not exist.

    This is the TOML intent *independent* of any env override — it lets
    operator surfaces warn when an env var silently differs from the
    operator's TOML configuration (issue #17192). *)
(** Pure resolution: parse TOML and determine which env vars would be
    overridden, without mutating the process-local boot override store.

    [~env_lookup] defaults to [Env_config_core.raw_value_opt]; tests inject a fake env
    to avoid global process env dependency.

    Returns [(count, overrides)] where [overrides] is
    [(env_name, value) list]. *)
val resolve_overrides :
  ?env_lookup:(string -> string option) ->
  Keeper_toml_loader.toml_doc ->
  int * (string * string) list

(** {1 Typed Keeper setting schema and validation} *)

val current_schema_version : int

type validation_severity =
  | Error
  | Warning

type validation_issue_kind =
  | Invalid_schema_version
  | Unknown_key
  | Type_mismatch
  | Out_of_range

type validation_issue =
  { key : string
  ; kind : validation_issue_kind
  ; severity : validation_severity
  ; detail : string
  }

type validation_report =
  { schema_version : int
  ; forward_schema : bool
  ; issues : validation_issue list
  }

val validate_doc : Keeper_toml_loader.toml_doc -> validation_report
val validate_source_text : string -> (validation_report, string) result
val validation_report_is_valid : validation_report -> bool
val validation_report_to_yojson : validation_report -> Yojson.Safe.t

val setting_schema_to_yojson : unit -> Yojson.Safe.t
(** Registry-generated schema for documentation and operator UI. *)

val settings_projection_to_yojson :
  Keeper_toml_loader.toml_doc -> Yojson.Safe.t
(** Per-setting configured/effective source, effect boundary, and consumer
    projection. Effective values reflect the current process snapshot; a newly
    saved startup overlay remains visibly pending until restart. *)

val overlay_application_to_yojson :
  Keeper_toml_loader.toml_doc -> Yojson.Safe.t
(** Aggregate startup-overlay application state for save/read responses. *)

(** TOML schema (for documentation):

    {[
      [heartbeat]
      sleep_chunk_sec             = 1.5

      [turn]
      # stream_idle_timeout_sec is intentionally omitted (disabled).
      [web_search]
      searxng_url                 = "http://localhost:8888"
      provider                    = "auto"
    ]}

    Keeper-owned unknown keys are validated explicitly; unrelated
    runtime/provider namespaces remain owned by their respective loaders. *)
