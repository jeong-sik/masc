type sandbox_profile =
  | Docker
  | Micro_vm
  | Remote_ssh
(** The profiles a keeper may run under.  There is no host arm. *)

module Sandbox_profile_tla : sig
  type t = sandbox_profile =
    | Docker [@tla.symbol "Docker"]
    | Micro_vm [@tla.symbol "Micro_vm"]
    | Remote_ssh [@tla.symbol "Remote_ssh"]
  [@@deriving tla]
end

type network_mode =
  | Network_none [@tla.symbol "Network_none"]
  | Network_inherit [@tla.symbol "Network_inherit"]
[@@deriving tla]

val sandbox_profile_to_string : sandbox_profile -> string
val sandbox_profile_of_string : string -> sandbox_profile option
val all_sandbox_profiles : sandbox_profile list
val valid_sandbox_profile_strings : string list
val network_mode_to_string : network_mode -> string
val network_mode_of_string : string -> network_mode option
val all_network_modes : network_mode list
val valid_network_mode_strings : string list
val default_network_mode_for_profile : sandbox_profile -> network_mode

(** Where a keeper's working tree lives, which decides how the host reaches
    a file in it.

    - [Shared_mount]: the tree is a host directory the sandbox mounts, so a
      host-side file operation on the playground reaches the same bytes the
      keeper's commands see.
    - [Endpoint_owned]: the tree lives on the endpoint (an OpenSSH host, or an
      Apple [container] guest's work volume). The host keeps only a
      bookkeeping bundle under the playground; every read and write of the
      tree goes through the remote lane ([Keeper_sandbox_remote]), and a
      host-side file operation on the bundle would silently miss the tree. *)
type tree_location =
  | Shared_mount
  | Endpoint_owned

val tree_location_of_profile : sandbox_profile -> tree_location
(** Docker and Micro_vm: [Shared_mount]. Remote_ssh: [Endpoint_owned]. *)

val backend_unimplemented_message : sandbox_profile -> string
(** The refusal a caller must surface when the declared profile has no
    runtime in this build. One sentence, shared by every dispatch surface,
    so an operator greps one string regardless of which entrypoint refused
    (typed Shell IR target, docker shell entrypoints, factory consumers). *)

