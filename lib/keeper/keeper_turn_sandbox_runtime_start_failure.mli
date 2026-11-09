(** Why a guest start fails and which side is at fault: the error of preparing
    a GitHub identity, the post-boot checks, the constructors of a microvm
    start failure with the sentence each one prints and the side it belongs
    to, and the request an Apple boot is compared and run with.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_turn_sandbox_runtime_record

(* Which side of a guest start a failure belongs to. The Keeper's GitHub
   identity is at fault only when the start itself refused that identity or
   a direct refresh, snapshot or revision check failed; every other cause is
   the sandbox's. Callers branch on the constructor, never on the detail
   text. *)
type github_identity_preparation_error =
  | Sandbox_unavailable of string
  | Identity_unavailable of string

val github_identity_preparation_error_message :
  github_identity_preparation_error -> string

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

val microvm_start_failure_message : microvm_start_failure -> string

val microvm_start_failure_cause :
  microvm_start_failure -> github_identity_preparation_error

val requested_apple_plan :
  t ->
  image:string ->
  guest_size:Keeper_microvm_guest_size.t ->
  identity_host_dir:string ->
  environment:(string * string) list ->
  config_mount:(string * string) option ->
  stable_labels:(string * string) list ->
  (Keeper_microvm_boot_plan.t, microvm_start_failure) result
