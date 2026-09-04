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

val network_mode_rejection : sandbox_profile -> network_mode -> string option
(** [None] when a keeper may hold that profile and that network mode together,
    and [Some message] naming the refusal when it may not.

    [Remote_ssh] with [Network_none] is the one refused pair: the SSH lane is
    transport-only, so it cannot cut the guest off from the network, and it
    says so rather than accepting the setting and ignoring it. Every other
    pair is accepted.

    Both the keeper TOML loader and the keeper_up argument resolver call this,
    so a declaration is refused before it is written as well as when it is
    read back. Only the loader checked before: a create wrote the pair
    unexamined, and the keeper TOML it produced was rejected by the next load
    of that same file. *)

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
(** Docker: [Shared_mount]. Micro_vm and Remote_ssh: [Endpoint_owned]. *)

val runs_in_disposable_guest : sandbox_profile -> bool
(** Whether the profile executes the payload inside a per-keeper disposable
    guest whose isolation is at least docker-grade: a hardened container
    ([Docker]) or a VM behind the hypervisor with its own kernel
    ([Micro_vm]). The payload reaches the guest as argv with no shell at any
    layer (docker exec takes argv; the microvm exec shim spawns with
    [Unix.execvpe] after jailing cwd under the work volume).

    [Remote_ssh] is excluded on purpose: it is transport-only — the
    container knobs are not reproduced and the network is inherited — so its
    requests keep paying the configured judgment path.

    This is the typed authority the observation-only gate classification
    ([Keeper_gate_readonly]) branches on; gate decisions never compare the
    profile's wire string. Adding a [sandbox_profile] constructor fails the
    build here until the new profile's answer is decided. *)

val backend_unimplemented_message : sandbox_profile -> string
(** The refusal a caller must surface when the declared profile has no
    runtime in this build. One sentence, shared by every dispatch surface,
    so an operator greps one string regardless of which entrypoint refused
    (typed Shell IR target, docker shell entrypoints, factory consumers). *)

