(** Config_doctor — Configuration health diagnostic for the MASC
    runtime.

    Inspects the resolved config root + persona overrides + cascade
    catalog + sandbox preflight and produces structured {!t}
    reports rendered as JSON ({!to_yojson}) or human text
    ({!render_text}) and graded by {!exit_code} for CLI use.

    Sister diagnostic to {!Auth_doctor} (cycle 174) — same status
    grade + exit_code mapping (Ok=0, Warn|Error=1).

    Internal: ~30+ helpers + 4 internal types stay private —
    \[trim_opt] (re-export of {!Env_config_core.trim_opt}),
    \[init_state_to_string] (status-side string projection of
    \[init_state]), \[dedupe_keep_order],
    \[canonicalize_path], \[runtime_data_root],
    \[repo_config_seed_path] (path resolvers), \[option_field],
    \[diagnose_cascade_catalog] /
    \[cascade_catalog_next_actions] (cascade catalog scanner),
    \[current_inputs] (Eio-aware inputs builder), the [Live_catalog_*]
    enum used in {!analyze_live}'s status grading, and pure
    \[analyze] (the lower-level entry behind {!analyze_with} +
    {!analyze_live}).  All consumed only inside the 5 public
    entries. *)

(** {1 Init state} *)

type init_state =
  | Initialized
  | Missing_init
  | Invalid_env
  | Shadowed
(** Whether the resolved base path is initialized as a MASC
    runtime directory. *)

(** {1 Status grade} *)

type status =
  | Ok
  | Warn
  | Error

val status_to_string : status -> string
(** [status_to_string s] returns the canonical lowercase label:
    ["ok"] / ["warn"] / ["error"].  Pinned literal — drift would
    break tooling that parses the config-doctor JSON. *)

(** {1 Inputs + report records} *)

type inputs = {
  cwd : string;
  executable_name : string;
  base_path_input : string;
  env_masc_base_path : string option;
  env_config_dir : string option;
  env_personas_dir : string option;
  resolution_source : string option;
  repo_config_fallback_enabled : bool;
}
(** Inputs to {!analyze_with}.  Concrete record because callers
    construct via [{ Config_doctor.cwd; ... }] at the dispatch
    site (notably tests). *)

type t = {
  status : status;
  init_state : init_state;
  base_path : string;
  active_config_root : string;
  active_personas_root : string;
  runtime_data_root : string;
  config_root_source : string;
  local_base_config_root : string;
  local_base_config_initialized : bool;
  explicit_config_dir : string option;
  explicit_personas_dir : string option;
  repo_config_seed_path : string option;
  repo_fallback_enabled : bool;
  keeper_runtime_toml_present : bool;
  warnings : string list;
  next_actions : string list;
  catalog_validation : Yojson.Safe.t option;
  sandbox_preflight : Yojson.Safe.t option;
}
(** Aggregate report.  Concrete record — callers (CLI rendering,
    tests, dashboard JSON) destructure fields directly.
    18 fields; new fields go through this contract. *)

(** {1 Catalog issue re-exports} *)

type catalog_issue_severity = Cascade_catalog_validator.severity =
  | Catalog_warn
  | Catalog_error
(** Severity grade for cascade catalog issues.  Re-exported with
    type identity preserved. *)

type catalog_issue = Cascade_catalog_validator.issue = {
  profile : string option;
  severity : catalog_issue_severity;
  message : string;
}
(** Cascade catalog validation issue.  Re-exported with type
    identity preserved. *)

(** {1 Path resolution} *)

val local_base_config_root : base_path:string -> string
(** [local_base_config_root ~base_path] returns the canonical
    location of the base config root under [base_path].
    Pinned at the contract seam — tests + dashboards both
    derive paths from this. *)

(** {1 Analysis (pure + live)} *)

val analyze_with : inputs -> t
(** [analyze_with inputs] runs the pure analysis stage
    (no Eio resources required).  Used by tests + offline
    diagnostic flows.  Subset of {!analyze_live} — does not
    inspect the live cascade catalog or sandbox preflight. *)

val analyze_live :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t ->
  base_path_input:string ->
  default_base_path:string ->
  unit ->
  t
(** [analyze_live ~sw ~net ~clock ~fs ~proc_mgr ~base_path_input
      ~default_base_path ()] runs the full analysis pipeline:

    + [analyze_with (current_inputs ...)] for the pure stage.
    + Initialise [Process_eio] with the resolved base path.
    + Run [Keeper_sandbox_runtime.docker_preflight] (10 s timeout).
    + Live cascade catalog validation (when reachable).
    + Combine into a final {!status} via the cascading severity
      ladder (Invalid_env / Missing_init -> Error; serving stale
      catalog -> Error; partial catalog -> Warn; etc.).

    Side-effecting (Process_eio init, Docker probe, file reads)
    but does not mutate persistent state. *)

(** {1 Rendering} *)

val to_yojson : t -> Yojson.Safe.t
(** [to_yojson report] renders the report as a JSON object for
    tool output and dashboard consumption. *)

val render_text : t -> string
(** [render_text report] returns a human-readable multi-line
    text rendering with section headers and bullet lists.  Used
    by the CLI [config doctor] subcommand. *)

val exit_code : t -> int
(** [exit_code report] returns the suggested process exit code:

    - {!Ok} -> [0]
    - {!Warn} -> [1] (warnings fail CI — same contract as
      {!Auth_doctor.exit_code})
    - {!Error} -> [1]

    Pinned at the contract seam: only {!Ok} status returns 0.
    Drift to permissive Warn=0 would silently swallow config
    misconfiguration alerts in CI gates. *)
