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
  | Multi_account_request
      (** [config.json] of the workspace asks for [Multi_account]
          ({!Authz_boot_mode_read.asked}). It is the one
          check of such a workspace beside [Workspace]: a boot runs the
          account server there, so imp's model, declaration, sandbox and
          history, which the server of a single user runs on, are not read.
          It is [Needs_verification]: whether the workspace is activated is
          judged by a boot, under the lease. *)
  | Unknown_account_mode
      (** [config.json] of the workspace holds an [account_mode] the boot
          does not know ({!Authz_boot_mode_read.asked}). It is the one check
          of such a workspace beside [Workspace], and it is [Invalid] with
          the sentence a boot refuses with
          ({!Authz_boot_mode.refusal_to_string}): no server boots there, so
          nothing a server runs on is read. *)
  | Person_account_homes
      (** A single-user workspace keeps [.masc/accounts], the runtime roots
          that persons left when its accounts were turned off or their log
          was removed ({!Runtime_account_home_layout.persons_remain}). The
          check is there only then: [Needs_setup] with the sentence of
          {!Runtime_account_access.person_homes_notice}, which names the
          model turns the server refuses and what opens them again, or
          [Needs_verification] when the directory could not be read. A
          workspace without the directory has no such check. *)

(** Whether an [Invalid] check keeps the workspace's existing history from opening.
    [Required_to_open]: the workspace, a loadable runtime.toml and Keeper
    metadata the boot admits. [Advisory] checks — imp's model binding,
    declaration and sandbox, and runtime roots that persons left behind — are
    reported but never send the operator back into setup. A request for accounts is
    [Required_to_open]: it decides which server boots. So is an account mode
    the boot does not know: no server boots on it. *)
type role = Required_to_open | Advisory

(** What a bare [masc] does with this observation: open the workspace's
    persisted Keeper history, walk the setup journey, or do neither because
    the workspace asks for accounts. The journey prepares the server of a
    single user and the history is what that server serves, so for an
    [Account_installation] it reports the account server and stops. For
    [Refused_by_boot] it reports the refusal and stops before it initializes
    anything: the config holds an account mode on which no boot runs a
    server. *)
type opening = Open_existing_history | Needs_journey | Account_installation | Refused_by_boot

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
    issues none, and neither does one that asks for accounts
    ([Multi_account_request]) or holds an account mode the boot does not know
    ([Unknown_account_mode]). *)
val inspect : sandbox:sandbox_observation -> base_path:string option -> t

(** {!inspect} for a running server. It never probes the sandbox
    ([Not_probed]): the server answers requests, and [masc doctor] is where
    the backend's state is read. *)
val inspect_loaded : base_path:string option -> t

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
    history, never about a running Keeper, model or sandbox.
    [Account_installation] is a workspace that holds a
    [Multi_account_request] check, whatever else it holds: a statement about
    what its config asks for, never about an account server that runs.
    [Refused_by_boot] is a workspace that holds an [Unknown_account_mode]
    check, whatever else it holds. *)
val opening : t -> opening
val to_json : t -> Yojson.Safe.t
val to_text : t -> string
