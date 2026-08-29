type command_result =
  { status : Unix.process_status
  ; output : string
  ; image : string
  ; network_label : string
  ; cwd : string
  }

type command_trust =
  | User_shell
  | Trusted_tool

type host_command =
  { env : string array option
  ; cwd : string option
  ; argv : string list
  }

type backend_command =
  { route_cwd : string
  ; cwd : unit -> string
  ; command_text : string
  ; network_mode : Keeper_types_profile_sandbox.network_mode
  ; trust : command_trust
  }

type routed_result =
  { status : Unix.process_status
  ; output : string
  ; via : string
  ; backend_error : string option
  }

type route =
  | Host
  | Sandbox_backend

module type Backend = sig
  val effective_sandbox_profile :
    meta:Keeper_meta_contract.keeper_meta ->
    Keeper_types_profile_sandbox.sandbox_profile * Keeper_types_profile_sandbox.network_mode

  val ensure_runtime :
    timeout_sec:float -> (string list, string) result

  val private_workspace_cwd :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    string ->
    string

  val run_shell_command_with_status :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    cwd:string ->
    timeout_sec:float ->
    cmd:string ->
    network_mode:Keeper_types_profile_sandbox.network_mode ->
    (command_result, string) result

  val run_trusted_shell_command_with_status :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    cwd:string ->
    timeout_sec:float ->
    cmd:string ->
    network_mode:Keeper_types_profile_sandbox.network_mode ->
    (command_result, string) result

  val run_bash :
    turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    cwd:string ->
    timeout_sec:float ->
    cmd:string ->
    network_mode:Keeper_types_profile_sandbox.network_mode ->
    string
end

module Make (Backend : Backend) = struct
  let effective_sandbox_profile = Backend.effective_sandbox_profile
  let ensure_runtime = Backend.ensure_runtime
  let private_workspace_cwd = Backend.private_workspace_cwd
  let run_shell_command_with_status = Backend.run_shell_command_with_status
  let run_trusted_shell_command_with_status =
    Backend.run_trusted_shell_command_with_status
  let run_bash = Backend.run_bash
end

let of_docker_result
    (result : Keeper_sandbox_docker.docker_shell_result)
  : command_result =
  { status = result.status
  ; output = result.output
  ; image = result.image
  ; network_label = result.network_label
  ; cwd = result.cwd
  }

module Docker_backend = struct
  let effective_sandbox_profile = Keeper_sandbox_docker.effective_sandbox_profile
  let ensure_runtime = Keeper_sandbox_docker.ensure_keeper_sandbox_runtime
  let private_workspace_cwd = Keeper_sandbox_docker.docker_private_workspace_cwd

  let run_shell_command_with_status ~config ~meta ~cwd ~timeout_sec ~cmd
      ~network_mode =
    Keeper_sandbox_docker.run_docker_shell_command_with_status
      ~config ~meta ~cwd ~timeout_sec ~cmd ~network_mode
    |> Result.map of_docker_result

  let run_trusted_shell_command_with_status ~config ~meta ~cwd ~timeout_sec ~cmd
      ~network_mode =
    Keeper_sandbox_docker.run_trusted_docker_shell_command_with_status
      ~config ~meta ~cwd ~timeout_sec ~cmd ~network_mode
    |> Result.map of_docker_result

  let run_bash = Keeper_sandbox_docker.run_docker_bash
end

include Make (Docker_backend)

let uses_backend ~config:_ ~meta ~cwd:_ =
  match effective_sandbox_profile ~meta with
  | Keeper_types_profile_sandbox.Docker, _ -> true
  (* Routed away from the host like Docker: the factory hands a VM keeper
     the same turn runtime, which builds Apple [container] argv for every
     CLI it starts (#31225, #31178). *)
  | Keeper_types_profile_sandbox.Micro_vm, _ -> true
  | Keeper_types_profile_sandbox.Local, _ -> false
  (* remote_ssh does not route through the (Docker) sandbox backend —
     answering [true] would silently downgrade it to Docker and [false]
     only means "not the Docker backend": the typed Execute dispatch
     fails closed on Remote_ssh before any Host route can claim it. *)
  | Keeper_types_profile_sandbox.Remote_ssh, _ -> false

let route_for ~config ~meta ~cwd =
  if uses_backend ~config ~meta ~cwd then Sandbox_backend else Host

let route_label = function
  | Host -> "host"
  | Sandbox_backend -> "docker"

let route_via ~config ~meta ~cwd =
  route_for ~config ~meta ~cwd |> route_label

let run_host_command ~timeout_sec (host : host_command) =
  let status, output =
    Process_eio.run_argv_with_status
      ~timeout_sec
      ?env:host.env
      ?cwd:host.cwd
      host.argv
  in
  { status; output; via = route_label Host; backend_error = None }

let run_backend_command ~config ~meta ~timeout_sec (backend : backend_command) =
  let cwd = backend.cwd () in
  let runner =
    match backend.trust with
    | User_shell -> run_shell_command_with_status
    | Trusted_tool -> run_trusted_shell_command_with_status
  in
  match
    runner
      ~config ~meta
      ~cwd
      ~timeout_sec
      ~cmd:backend.command_text
      ~network_mode:backend.network_mode
  with
  | Ok result ->
    { status = result.status
    ; output = result.output
    ; via = route_label Sandbox_backend
    ; backend_error = None
    }
  | Error msg ->
    { status = Unix.WEXITED 127
    ; output = msg
    ; via = route_label Sandbox_backend
    ; backend_error = Some msg
    }

let run_command_with_status ~config ~meta ~timeout_sec ~host ~backend =
  match effective_sandbox_profile ~meta with
  (* Fail closed, never a silent host route (RFC-0001): [route_for]
     classifies Remote_ssh as "not the Docker backend", which would
     otherwise fall through to [run_host_command] here. A remote_ssh
     keeper does not pass through this router at all. *)
  | Keeper_types_profile_sandbox.Remote_ssh, _ ->
    Error
      "remote_ssh_dispatch_unavailable: this router serves the Docker and \
       host backends; a remote_ssh keeper dispatches through the SSH \
       runner instead, and there is no fallback to docker or host dispatch"
  (* [Micro_vm] routes exactly as on main: [uses_backend] classifies it as
     the sandbox backend, and the docker-shell entrypoints refuse the
     profile themselves before building an argv. *)
  | ( Keeper_types_profile_sandbox.Docker
    | Keeper_types_profile_sandbox.Micro_vm
    | Keeper_types_profile_sandbox.Local )
    , _
    ->
    (match route_for ~config ~meta ~cwd:backend.route_cwd with
     | Sandbox_backend ->
       Ok (run_backend_command ~config ~meta ~timeout_sec backend)
     | Host -> Ok (run_host_command ~timeout_sec host))
