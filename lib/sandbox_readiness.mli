(** Read-only prerequisites for setup and configuration UIs. Service readiness
    is not proof that a guest booted or that its tools work. *)
type architecture = Arm64 | X64
type host = Macos of { architecture : architecture; major : int } | Linux of architecture | Unsupported
type backend = Docker | Apple_container | Nerdctl_kata | Microsandbox | Remote_ssh
type state = Service_ready | Missing_prerequisite of string | Unsupported_host of string
  | Unsupported_capability of string | Probe_failed of string | Needs_configuration of string
type guest_verification = Not_run
type entry = { backend : backend; state : state; guest_verification : guest_verification }
type selection = { backend : backend; network_mode : Keeper_types_profile_sandbox.network_mode;
                   remote_endpoint : string option }
type command_error = Missing_command | Command_failed
type declaration_fault = Declaration_invalid | Declaration_unreadable
(** Why imp's declared sandbox could not be turned into a selection:
    [Declaration_unreadable] carries the OS message from opening imp.toml,
    [Declaration_invalid] carries the parse or selection reason. *)
type configuration_error = { kind : declaration_fault; detail : string }
type runner = string list -> (string, command_error) result
val all : backend list
val backend_id : backend -> string
val backend_of_id : string -> backend option
val profile : backend -> Keeper_sandbox_config.sandbox_profile
val microvm_backend : backend -> Keeper_microvm_backend.t option
val detect_host : run:runner -> host
type builder_rosetta = Rosetta_not_used | Rosetta_installed | Rosetta_missing
(** Whether Apple Container's image builder can start on this Mac. The builder
    VM uses Rosetta unless [build] rosetta = false, and does not start when
    Rosetta is absent. [Rosetta_not_used]: Rosetta is absent and the setting
    is false. [Rosetta_missing]: Rosetta is absent and the setting is true or
    could not be read, which Apple's default makes true. *)
val apple_builder_rosetta : run:runner -> (builder_rosetta, string) result
(** Reads Rosetta's installer receipt, then
    [container system property list --format json] only when Rosetta is
    absent. [Error] only when the receipt could not be asked about. *)
val apple_container_needs_rosetta : run:runner -> bool
(** The Apple Container service answered its inventory, and its builder cannot
    start: [apple_builder_rosetta] is [Rosetta_missing]. False for a service
    that is absent or stopped, which needs installing or starting first. *)
val apple_container_needs_default_kernel : run:runner -> bool
(** The Apple Container service answered its inventory and its builder starts,
    but no default kernel is configured, so the first image build would die
    with "default kernel not configured". False for a service that is absent
    or stopped, which needs installing or starting first. *)
val kernel_missing_reason : string
(** The missing-prerequisite reason [probe] reports for that state; published
    so the readiness answer and the offered action name the same piece. *)
val probe : host:host -> run:runner -> require_rootless:bool -> require_userns:bool -> backend -> entry
val recommend : host:host -> configured:backend option -> entry list -> backend option
val catalog_json : host:host -> configured:backend option -> entry list -> Yojson.Safe.t
val declaration : base_path:string -> (selection, configuration_error) result
(** Read imp's declared sandbox from the workspace. No request overrides and
    no host default: a microvm profile without a named backend is invalid. *)
val configuration_error_json : configuration_error -> Yojson.Safe.t
val inspect : base_path:string option -> Yojson.Safe.t
(** Observe the declared sandbox and host services without changing either.
    A declaration that cannot be read or selected is returned under
    [configuration_error] as [configuration_error_json], never as a sentence
    that hides the reason. *)
val state_message : state -> string
val system_runner : runner
val selection_of_contents : path:string -> contents:string ->
  profile:Keeper_sandbox_config.sandbox_profile option ->
  microvm_backend:Keeper_microvm_backend.t option ->
  network_mode:Keeper_types_profile_sandbox.network_mode option -> (selection, string) result
val stage_contents : path:string -> contents:string -> selection -> (string, string) result
val commit_staged : path:string -> original:string -> staged:string -> (unit, string) result
(** Commit under the keeper manifest lock only if captured bytes still match. *)
