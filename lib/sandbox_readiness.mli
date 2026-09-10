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
val inspect : base_path:string option -> Yojson.Safe.t
(** Observe the declared sandbox and host services without changing either.
    An unreadable declaration is returned as an explicit configuration error. *)
val state_message : state -> string
val system_runner : runner
val selection_of_contents : host:host -> path:string -> contents:string ->
  profile:Keeper_sandbox_config.sandbox_profile option ->
  microvm_backend:Keeper_microvm_backend.t option ->
  network_mode:Keeper_types_profile_sandbox.network_mode option -> (selection, string) result
val stage_contents : path:string -> contents:string -> selection -> (string, string) result
val commit_staged_with_publication : with_publication:((unit -> (unit,string) result) -> (unit,string) result) -> path:string -> original:string -> staged:string -> (unit, string) result
(** Commit under the keeper manifest lock only if captured bytes still match.
    [with_publication] may add an owner lifecycle guard around the actual CAS
    and write, after the manifest lock is acquired. Preserve manifest-before-
    lifecycle lock ordering; the default publishes directly. *)

val commit_staged : path:string -> original:string -> staged:string -> (unit,string) result
