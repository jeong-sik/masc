open Keeper_meta_contract
open Keeper_types_profile
open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_container
open Keeper_turn_sandbox_runtime_work_volume

(* Which side of a guest start a failure belongs to. The Keeper's GitHub
   identity is at fault only when the start itself refused that identity or
   a direct refresh, snapshot or revision check failed; every other cause is
   the sandbox's. Callers branch on the constructor, never on the detail
   text. *)
type github_identity_preparation_error =
  | Sandbox_unavailable of string
  | Identity_unavailable of string

let github_identity_preparation_error_message = function
  | Sandbox_unavailable detail | Identity_unavailable detail -> detail
;;

(* Why a guest did not come up. A name the runtime refuses is not one of
   them: [Keeper_sandbox_container_name] builds only names every microVM
   runtime accepts. An arm that wraps what another step or the runtime's CLI
   said keeps that text whole in a field; the sentence an operator reads is
   written once, in [microvm_start_failure_message]. *)
type microvm_post_boot_check =
  | Runtime_does_not_list
  | Work_root_unusable

type microvm_start_failure =
  | Backend_unresolved of string
  | Build_cleanup_unresolved of string
  | Runtime_context_unavailable
  | Guest_identity_store_unavailable of Keeper_microvm_github_identity.error
  | Guest_facts_refused of Keeper_microvm_boot_plan.refusal
  | Guest_ownership_unverified of string
  | Image_unresolved of Keeper_sandbox_image_resolver.error
  | Guest_state_unreadable of string
  | Guest_size_invalid of string
      (** Neither the keeper nor the workspace names a size that parses, so
          there is nothing to boot the guest with or compare a running one
          against. *)
  | Agent_socket_unavailable of Keeper_microvm_agent_socket.preparation_error
      (** The host end of the agent's socket could not be made ready before
          the boot that publishes it. *)
  | Agent_unchecked of string
      (** A running agent guest could not be asked for its hello, so it is
          neither adopted nor replaced. *)
  | Unadoptable_guest_not_removed of string
      (** A running guest that may not be adopted -- its snapshot died with
          an older server, or its image, size or proxy port is not what the
          keeper asks for now -- and would not go. *)
  | Previous_mode_guest_not_removed of { container_name : string; detail : string }
      (** Every network mode shares the Keeper's volumes. A previous mode
          must release them before any fresh boot can recreate or trim them. *)
  | Adopted_guest_volume_unverified of string
  | Guest_provisions_unavailable of string
  | Github_identity_invalid of string
  | Policy_network_unavailable of string
  | Network_unexpressible of string
  | Invalid_boot_plan of Keeper_microvm_boot_plan.invalid_plan list
  | Constraints_unexpressible of
      { backend : Keeper_microvm_backend.t
      ; refusals : Keeper_sandbox_microvm.constraint_refusal list
      }
  | Booted_guest_unusable of
      { check : microvm_post_boot_check
      ; container_name : string
      ; detail : string
      }
  | Booted_guest_state_unknown of
      { container_name : string
      ; detail : string
      }
      (** The boot argv exited 0 and the runtime could not then be asked
          about the guest. The guest is left running with its snapshot and
          boot record; the next start probes it again. *)
  | Boot_command_failed of
      { status : Unix.process_status
      ; output : string
      }
      (** The boot argv exited non-zero and no guest is running under the
          name, or its state could not be read. *)

let microvm_post_boot_check_label = function
  | Runtime_does_not_list -> "container ran but the runtime does not list it"
  | Work_root_unusable ->
    "guest cannot prove its work volume is mounted and its keeper root usable"
;;

let microvm_start_failure_message failure =
  let failed detail = "microvm_start_failed: " ^ detail in
  match failure with
  | Runtime_context_unavailable -> failed "microvm runtime filesystem or Eio execution is unavailable"
  | Guest_identity_store_unavailable error -> failed (Keeper_microvm_github_identity.error_message error)
  | Guest_facts_refused refusal ->
    failed (Keeper_microvm_boot_plan.refusal_message refusal)
  | Backend_unresolved detail
  | Build_cleanup_unresolved detail
  | Guest_state_unreadable detail
  | Guest_ownership_unverified detail
  | Adopted_guest_volume_unverified detail
  | Guest_provisions_unavailable detail
  | Policy_network_unavailable detail
  | Network_unexpressible detail -> failed detail
  | Image_unresolved error -> failed (image_unresolved_message error)
  | Guest_size_invalid detail -> failed ("microvm_guest_size_invalid: " ^ detail)
  | Agent_socket_unavailable error ->
    failed (Keeper_microvm_agent_socket.preparation_error_message error)
  | Agent_unchecked detail -> failed ("microvm_agent_unchecked: " ^ detail)
  | Unadoptable_guest_not_removed detail ->
    failed ("a running guest that cannot be adopted was not removed: " ^ detail)
  | Previous_mode_guest_not_removed { container_name; detail } ->
    failed (Printf.sprintf "previous network-mode guest %s was not removed: %s"
      container_name detail)
  | Github_identity_invalid detail -> failed ("github_identity_invalid: " ^ detail)
  | Constraints_unexpressible { backend; refusals } ->
    failed (Keeper_sandbox_microvm.constraint_refusals_message backend refusals)
  | Invalid_boot_plan errors ->
    failed ("invalid boot plan: " ^ String.concat "; "
      (List.map Keeper_microvm_boot_plan.invalid_plan_message errors))
  | Booted_guest_unusable { check; container_name; detail } ->
    failed
      (Printf.sprintf
         "%s %s: %s"
         (microvm_post_boot_check_label check)
         container_name
         detail)
  | Booted_guest_state_unknown { container_name; detail } ->
    failed
      (Printf.sprintf
         "guest %s booted and was left running; its state could not be read: %s"
         container_name
         detail)
  | Boot_command_failed { status; output } ->
    failed
      (Printf.sprintf
         "boot %s: %s"
         (Keeper_sandbox_exec_failure.status_label status)
         (Keeper_sandbox_runtime.docker_failure_output_for_log output))
;;

(* Only a rejected GitHub identity is the Keeper's login at fault. Every
   constructor is named, so a new failure has to choose a side here. *)
let microvm_start_failure_cause failure =
  let detail = microvm_start_failure_message failure in
  match failure with
  | Github_identity_invalid _ -> Identity_unavailable detail
  | Backend_unresolved _
  | Build_cleanup_unresolved _
  | Runtime_context_unavailable
  (* [Guest_identity_store_unavailable] is named for what the store holds, the
     credential snapshot. It fails in the host's filesystem, registry, lock or
     lifecycle checks, which say nothing about whether the login is valid. *)
  | Guest_identity_store_unavailable _
  | Guest_facts_refused _
  | Guest_ownership_unverified _
  | Image_unresolved _
  | Guest_state_unreadable _
  | Guest_size_invalid _
  | Agent_socket_unavailable _
  | Agent_unchecked _
  | Unadoptable_guest_not_removed _
  | Previous_mode_guest_not_removed _
  | Adopted_guest_volume_unverified _
  | Guest_provisions_unavailable _
  | Policy_network_unavailable _
  | Network_unexpressible _
  | Invalid_boot_plan _
  | Constraints_unexpressible _
  | Booted_guest_unusable _
  | Booted_guest_state_unknown _
  | Boot_command_failed _ -> Sandbox_unavailable detail
;;

(* The same immutable request drives comparison and Boot argv. Volume names,
   mount sources and stable labels are projections here; provisioning and
   policy route discovery belong to the Boot execution. An Apple guest's first
   process is always the shim's agent ({!Keeper_microvm_backend.request_delivery}). *)
let requested_apple_plan (t : t) ~image ~guest_size ~identity_host_dir ~environment
    ~config_mount ~stable_labels =
  let open Result.Syntax in
  let volume_name result = Result.map_error (fun detail -> Guest_provisions_unavailable detail) result in
  let* work_volume_name = volume_name (Keeper_sandbox_microvm.work_volume_name ~keeper_name:t.meta.name) in
  let* build_volume_name = volume_name (Keeper_sandbox_microvm.build_volume_name ~keeper_name:t.meta.name) in
  let module Plan = Keeper_microvm_boot_plan in
  let container_masc_dir = Keeper_sandbox_runtime_setup.container_masc_dir ~container_root:t.container_root in
  let identity_destination = Keeper_github_identity.container_config_dir
      ~container_masc_dir ~keeper_name:t.meta.name in
  let config_mount = match config_mount with
    | None -> []
    | Some (source, destination) -> [Plan.Host_dir {source; destination; read_only=true}] in
  let network = Keeper_sandbox_microvm.boot_plan_network ~keeper_name:t.meta.name t.network_mode in
  let mounts = config_mount
    @ [Plan.Host_dir {source=identity_host_dir; destination=identity_destination; read_only=true}
      ; Plan.Named_volume {name=work_volume_name; destination=Keeper_sandbox_microvm.work_volume_guest_root}
      ; Plan.Named_volume {name=build_volume_name; destination=Keeper_sandbox_microvm.build_volume_guest_root}
      ; Plan.Host_dir {source=microvm_shim_host_dir t; destination=Keeper_sandbox_microvm.shim_guest_dir; read_only=true}] in
  Ok (Keeper_microvm_agent_socket.plan ~uid:t.uid ~gid:t.gid
        ~host_socket:(Keeper_microvm_agent_socket.host_path ~base_path:t.config.base_path
                        ~guest_name:(keeper_vm_name t))
        ~image ~guest_size ~mounts ~network ~environment
        ~labels:(stable_labels @ [Keeper_sandbox_microvm.microvm_backend_label_key,
          Keeper_microvm_backend.to_string Keeper_microvm_backend.Apple_container]))
