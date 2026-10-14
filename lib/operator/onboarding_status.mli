(** Read-only first-run observations, shared by the CLI and operator HTTP UI.
    Declaration, verification and execution are separate facts. Inspecting this
    document never starts a model, creates a workspace, or changes configuration. *)
type action = Choose_workspace | Initialize_workspace | Configure_models
  | Configure_sandbox | Start_imp | Inspect_configuration

type condition = Satisfied | Needs_setup | Needs_verification | Invalid

type check_id =
  | Workspace
  | Runtime_configuration
  | Model_connection
  | Keeper_declaration
  | Sandbox
  | Keeper_persistence
  | Browser_lane
  | Browser_bidi_host
      (** Whether a BiDi browser host runs for the workspace and why the last
          one ended, from that host's record on disk. *)

(** Whether an [Invalid] check keeps the workspace's existing history from opening.
    [Required_to_open]: the workspace, a loadable runtime.toml and Keeper
    metadata the boot admits. [Advisory] checks — imp's model binding,
    declaration and sandbox, and the browser lane — are reported but never
    send the operator back into setup. *)
type role = Required_to_open | Advisory

(** What a bare [masc] does with this observation: open the workspace's
    persisted Keeper history, or walk the setup journey. *)
type opening = Open_existing_history | Needs_journey

type check =
  { id : check_id
  ; condition : condition
  ; message : string
  ; actions : action list
  }

type t =
  { base_path : string option
  ; checks : check list
  ; selected_runtime : string option
  ; selected_model : string option
  }

(** Whether an inspection reads the declared sandbox backend's state. A server
    answering requests chooses [Not_probed]: probing spawns commands, and a
    stopped daemon would then hold every answer for its timeout. *)
type sandbox_observation =
  | Probe_with of Sandbox_readiness.runner
  (** Probe with this runner: the host's {!Sandbox_readiness.system_runner} in
      the CLI, a fixture in tests. *)
  | Not_probed
  (** Issue no command. A declared backend is [Needs_verification]. *)

(** [keeper_persistence] is Satisfied when the workspace holds Keeper
    metadata, whichever Keepers they are, and every file passes the check the
    server's boot reconcile applies. No metadata is Needs_setup; any file that
    fails it is Invalid, because the server refuses to boot on it. Persistence
    does not establish model, sandbox or running health.

    With [Probe_with] the declared sandbox backend is probed through that
    runner. The probe issues read-only commands only (host detection, then the
    backend's inventory and, for Apple Container, Rosetta and kernel settings),
    at most seven per inspection. A workspace with no readable imp declaration
    issues none. *)
val inspect : sandbox:sandbox_observation -> base_path:string option -> t

(** {!inspect} for a running server: who starts the Keeper Firefox is read
    from the browser configuration it loaded, which its other answers use,
    and not from the file. {!inspect} reads the workspace's [runtime.toml]
    and uses its browser tables only when the whole file loads. It never
    probes the sandbox ([Not_probed]): the server answers requests, and
    [masc doctor] is where the backend's state is read. *)
val inspect_loaded : configuration:Browser_configuration.t option -> base_path:string option -> t

(** How the doctor reports one probed sandbox backend. [Service_ready] is
    [Needs_verification]: the service answered and no guest was booted.
    [Missing_prerequisite], [Unsupported_host], [Unsupported_capability] and
    [Probe_failed] are [Needs_setup] carrying the probe's reason, so a backend
    that cannot be used now is never read as one that merely was not verified.
    [Needs_configuration] is [Needs_verification]: it is raised for remote SSH,
    which the probe cannot observe, and the declaration already names the
    endpoint the probe's reason asks for, so that reason is not shown and the
    message says the server verifies the declared endpoint. *)
val sandbox_check_of_entry : Sandbox_readiness.entry -> check

(** The wire name of a check, as serialized in [id]. *)
val check_id_name : check_id -> string

val role : check_id -> role

(** [Open_existing_history] needs [workspace], [runtime_configuration] and
    [keeper_persistence] Satisfied, and no [Required_to_open] check Invalid. It is a statement about readable
    history, never about a running Keeper, model or sandbox. *)
val opening : t -> opening
val to_json : t -> Yojson.Safe.t
val to_text : t -> string
