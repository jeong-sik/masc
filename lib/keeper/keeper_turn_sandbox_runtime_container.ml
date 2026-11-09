open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_registry
open Keeper_turn_sandbox_runtime_boot
open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_run_argv

let is_microvm (t : t) =
  t.meta.sandbox_profile = Keeper_types_profile_sandbox.Micro_vm
;;

(* Which runtime this guest is on. [effective_meta_of_profile_defaults]
   resolves it and refuses a Micro_vm keeper that has none, so a guest that
   reached dispatch has one -- but two constructors write the field directly
   ([Keeper_turn_up_create], [Keeper_meta_json_parse]), so the empty case is
   reachable. It is a refusal rather than an assumed runtime: naming Apple
   here is how a keeper that declared microsandbox booted under container
   and was then stopped with msb (#32837). *)
let microvm_backend_of_meta (meta : keeper_meta) =
  match meta.microvm_backend with
  | Some backend -> Ok backend
  | None ->
    Error
      (Printf.sprintf
         "microvm_backend_unresolved: keeper %s declares sandbox_profile=microvm \
          and no microvm_backend, so there is no runtime to boot it on. Next: \
          set microvm_backend in the keeper's TOML to one of: %s"
         meta.name
         (String.concat ", " Keeper_microvm_backend.valid_strings))
;;

let microvm_backend_of (t : t) = microvm_backend_of_meta t.meta

(* The Docker exec prefix: [docker exec [-i] --user u:g -w cwd [env...]].
   Only the Docker lane execs into a mounted tree. A microvm guest owns its
   tree on the work volume and is reached through the shim over the remote
   lane (RFC-0400), so every exec entrypoint below refuses it first. *)
let exec_prefix (t : t) ~container_cwd ~stdin =
  Keeper_sandbox_runtime.docker_command_argv ()
  @ [ "exec" ]
  @ (if stdin then [ "-i" ] else [])
  @ [ "--user"; Printf.sprintf "%d:%d" t.uid t.gid; "-w"; container_cwd ]
  @ Keeper_sandbox_runtime.docker_sandbox_env_args
      ~base_path:t.config.base_path
      ~container_root:t.container_root
;;

let docker_exec_only (t : t) =
  if is_microvm t
  then
    Error
      (Printf.sprintf
         "microvm_exec_is_remote: keeper %s's guest owns its tree on the work volume; commands reach it through the remote lane (Keeper_sandbox_remote), not a docker-shaped exec"
         t.meta.name)
  else Ok ()
;;

(* Whether the Docker daemon can see the named container, in any state. A
   microvm guest is asked through [probe_microvm_container_state], which also
   tells a missing guest from a runtime that could not be asked. *)
let inspect_container_exists ?timeout_sec container_name =
  let inspect_argv =
    Keeper_sandbox_runtime.docker_command_argv ()
    @ [ "inspect"; "--format"; "{{.Id}}"; container_name ]
  in
  let inspect_st, inspect_out =
    run_argv_with_status ?timeout_sec inspect_argv
  in
  match inspect_st with
  | Unix.WEXITED 0 -> Ok ()
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error inspect_out
;;

(* An inspect that exits 0 is the whole answer. Any other end -- a missing
   name, an apiserver that stalled before it could look, a timeout -- is
   followed by the runtime's own listing, so [Docker_container_absent] means
   a listing was read and the name is not in it, and [Error] means nobody
   could say (#44676). *)
let probe_microvm_container_state ?timeout_sec ~backend container_name =
  let inspect =
    run_argv_with_status
      ?timeout_sec
      (Keeper_sandbox_microvm.inspect_argv_for backend ~container_name)
  in
  let listing =
    match inspect with
    | Unix.WEXITED 0, _ -> None
    | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ ->
      Some
        (run_argv_with_status_split
           ?timeout_sec
           (Keeper_sandbox_microvm.guest_listing_argv_for backend))
  in
  Keeper_sandbox_microvm.classify_guest_probe_for
    backend
    ~container_name
    ~inspect
    ~listing
;;

let inspect_container_running ?timeout_sec container_name =
  match
    Keeper_sandbox_runtime.probe_container_state_optional ~container_name ?timeout_sec ()
  with
  | Ok Keeper_sandbox_runtime.Docker_container_running -> Ok ()
  | Ok Keeper_sandbox_runtime.Docker_container_stopped ->
    Error (Printf.sprintf "docker container %s is stopped" container_name)
  | Ok Keeper_sandbox_runtime.Docker_container_absent ->
    Error (Printf.sprintf "docker container %s is absent" container_name)
  | Error _ as error -> error
;;

type failed_exec_recovery =
  | Preserve_failed_exec
  | Restart_failed_exec
  | Failed_exec_state_probe_error of string

(* Asked only after a Docker exec failed: every exec entrypoint runs
   [docker_exec_only] first, which refuses a microvm runtime. *)
let failed_exec_recovery ?timeout_sec (t : t) =
  match get_state t with
  | Not_started -> Restart_failed_exec
  | Running { container_name } ->
    (match
       Keeper_sandbox_runtime.probe_container_state_optional
         ~container_name
         ?timeout_sec
         ()
     with
     | Ok Keeper_sandbox_runtime.Docker_container_running -> Preserve_failed_exec
     | Ok Keeper_sandbox_runtime.Docker_container_stopped
     | Ok Keeper_sandbox_runtime.Docker_container_absent -> Restart_failed_exec
     | Error detail -> Failed_exec_state_probe_error detail)
;;

let failed_exec_state_probe_error ~status ~output detail =
  Printf.sprintf
    "docker_container_state_probe_failed_after_exec: status=%s output=%s probe_error=%s"
    (Keeper_sandbox_exec_failure.status_label status)
    (Keeper_sandbox_runtime.docker_failure_output_for_log output)
    detail
;;

(* A microvm guest mounts its work volume, the shim, runtime config, and its
   immutable GitHub identity snapshot -- never the host playground. It still
   has no generic secret projection or workspace-state mounts, and no
   seccomp/pids/security-opt flags (container rejects those; the guest kernel
   is the boundary). *)
(* One guest per keeper, not per turn: the name is stable, an already
   running guest is adopted instead of booted (amortising the 1.3-2.4s VM
   start to once per keeper), and turn cleanup leaves it running. State
   accumulated inside the guest between turns belongs to the same keeper.
   Teardown is [teardown_keeper_sandbox], which shutdown finalization runs after
   the registry unregister succeeds -- the one point that knows the keeper is
   gone for good rather than between turns. *)
(* The network mode is in the name for the reason it is in the Docker
   container's: adopt matches by name, so a name that ignores the mode lets a
   guest booted under one policy be adopted under another.

   For [Network_policy] that is not only a wrong network. The guest carries
   the proxy address in its environment, and the port is ephemeral, so a
   guest adopted across a server restart would keep CONNECTing to a port
   nothing is listening on -- no refusal, no event, and a keeper that looks
   idle rather than cut off. A distinct name makes that guest a different
   guest, so it is replaced instead of adopted. *)
let microvm_container_name ~(config : Workspace.config) ~keeper_name ~network_mode =
  Keeper_sandbox_container_name.make
    (Keeper_sandbox_container_name.Micro_vm_persistent
       { keeper_name; network_mode; base_path = config.base_path })
  |> Keeper_sandbox_container_name.to_string
;;

(* The port is read from the keeper's registry entry rather than carried in
   the turn state: the proxy is bound once per keeper lane and a guest boots
   per turn, so the two ends have different lifetimes and the entry is what
   both can see. [None] means no listener -- the lane is down, or its fiber
   died -- and no guest may be pointed at it. *)
let bound_egress_proxy_port (t : t) =
  Keeper_registry.get ~base_path:t.config.base_path t.meta.name
  |> Option.map (fun (entry : Keeper_registry_types.registry_entry) ->
       Atomic.get entry.egress_proxy_port)
  |> Option.join
;;

let keeper_vm_name (t : t) =
  microvm_container_name
    ~config:t.config
    ~keeper_name:t.meta.name
    ~network_mode:t.network_mode
;;

let bind_registered_microvm_identity t container_name =
  match microvm_identity_snapshot container_name with
  | None -> None
  | Some snapshot ->
    bind_github_identity_snapshot t (Process_identity snapshot);
    Some snapshot
;;

let stop_and_delete_microvm_container ?timeout_sec ~backend container_name =
  let stop_st, stop_out =
    run_argv_with_status
      ?timeout_sec
      (Keeper_sandbox_microvm.stop_argv_for backend ~container_name)
  in
  let delete_st, delete_out =
    run_argv_with_status
      ?timeout_sec
      (Keeper_sandbox_microvm.delete_force_argv_for backend ~container_name)
  in
  (* Both commands can race a guest that is already absent, so their exit
     codes are only diagnostics. The postcondition is authoritative: do not
     release the intended host identity snapshot until the guest name is gone. *)
  let absence = match backend with
    | Keeper_microvm_backend.Apple_container ->
      let timeout_sec = match timeout_sec with Some seconds -> seconds
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm () in
      Keeper_microvm_guest_inventory.read ~backend ~guest_name:container_name ~timeout_sec
      |> Result.map (function
        | Keeper_microvm_guest_inventory.Absent -> Keeper_sandbox_runtime.Docker_container_absent
        | Keeper_microvm_guest_inventory.Present -> Keeper_sandbox_runtime.Docker_container_running)
      |> Result.map_error Keeper_microvm_guest_inventory.error_message
    | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
      probe_microvm_container_state ?timeout_sec ~backend container_name in
  match absence with
  | Ok Keeper_sandbox_runtime.Docker_container_absent ->
    forget_microvm_guest_state ~backend ~container_name;
    Ok ()
  | Ok Keeper_sandbox_runtime.Docker_container_running
  | Ok Keeper_sandbox_runtime.Docker_container_stopped ->
    Error
      (Printf.sprintf
         "microvm_teardown_failed: guest remains after stop=%s (%s), delete=%s (%s)"
         (Keeper_sandbox_exec_failure.status_label stop_st)
         (Keeper_sandbox_runtime.docker_failure_output_for_log stop_out)
         (Keeper_sandbox_exec_failure.status_label delete_st)
         (Keeper_sandbox_runtime.docker_failure_output_for_log delete_out))
  | Error probe_error ->
    Error
      (Printf.sprintf
         "microvm_teardown_failed: post-delete state unknown: %s; stop=%s (%s), delete=%s (%s)"
         probe_error
         (Keeper_sandbox_exec_failure.status_label stop_st)
         (Keeper_sandbox_runtime.docker_failure_output_for_log stop_out)
         (Keeper_sandbox_exec_failure.status_label delete_st)
         (Keeper_sandbox_runtime.docker_failure_output_for_log delete_out))
;;
