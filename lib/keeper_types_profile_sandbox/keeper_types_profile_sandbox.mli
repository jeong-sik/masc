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

val backend_unimplemented_message : sandbox_profile -> string
(** The refusal a caller must surface when the declared profile has no
    runtime in this build. One sentence, shared by every dispatch surface,
    so an operator greps one string regardless of which entrypoint refused
    (typed Shell IR target, docker shell entrypoints, factory consumers). *)

