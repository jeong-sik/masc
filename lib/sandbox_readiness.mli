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
