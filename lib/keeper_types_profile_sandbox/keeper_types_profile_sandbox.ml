type sandbox_profile =
  | Docker
    (** Containerized execution with hardened defaults: cap-drop,
        no-new-privs, read-only rootfs, tmpfs, pids/memory limits.
        Network defaults to [Network_none]. *)
  | Micro_vm
    (** One lightweight virtual machine per container, through Apple's
        [container] CLI on macOS 26+. The guest runs its own Linux kernel,
        so an escape has to cross the hypervisor rather than a shared
        kernel. Measured 2026-08-28 on an M3 Max: about 460 MB of host
        memory per running guest, a 1.3-2.4s boot paid once per keeper
        (#31340 adopts the guest across turns), and 0.06-0.10s per call
        after that. Network defaults to [Network_none]. *)
  | Remote_ssh
    (** Execution on a remote host over SSH (Phase 1 lane,
        docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md
        {e 4.2}). Transport-only: the Docker container knobs are not
        reproduced, [network_mode = "none"] is rejected at config load
        ([remote_ssh_no_network_mode]), and the only accepted network
        mode is [Network_inherit] (the default). Execute and read dispatch
        run over the SSH runner; the Docker-shaped arms refuse this profile
        rather than falling back to a host route. *)

module Sandbox_profile_tla = struct
  type t = sandbox_profile =
    | Docker [@tla.symbol "Docker"]
    | Micro_vm [@tla.symbol "Micro_vm"]
    | Remote_ssh [@tla.symbol "Remote_ssh"]
  [@@deriving tla]
end
(** TLA+ dispatch symbols for {!sandbox_profile}. Kept in a submodule
    so the generated [to_tla_symbol] / [all_symbols] / [all_states]
    names cannot be shadowed by the separate [network_mode] deriver
    below. Matches [ProfileSet] in
    [specs/boundary/SandboxDispatch.tla]. *)

type network_mode =
  | Network_none [@tla.symbol "Network_none"]
  | Network_inherit [@tla.symbol "Network_inherit"]
[@@deriving tla]

let sandbox_profile_to_config = function
  | Docker -> Keeper_sandbox_config.Docker
  | Micro_vm -> Keeper_sandbox_config.Micro_vm
  | Remote_ssh -> Keeper_sandbox_config.Remote_ssh

let sandbox_profile_of_config = function
  | Keeper_sandbox_config.Docker -> Docker
  | Keeper_sandbox_config.Micro_vm -> Micro_vm
  | Keeper_sandbox_config.Remote_ssh -> Remote_ssh

let sandbox_profile_to_string profile =
  profile
  |> sandbox_profile_to_config
  |> Keeper_sandbox_config.sandbox_profile_to_string
;;

(** Parse a sandbox profile string. Canonical values are ["docker"],
    ["microvm"] and ["remote_ssh"]. *)
let sandbox_profile_of_string raw =
  raw
  |> Keeper_sandbox_config.sandbox_profile_of_string
  |> Option.map sandbox_profile_of_config
;;

(* Issue #8467: Variant SSOT — adding a constructor to [sandbox_profile]
   forces [sandbox_profile_to_string] exhaustiveness AND extends
   [valid_sandbox_profile_strings] so [keeper_schema] picks it up via
   the mirror declared there. *)
let all_sandbox_profiles = [ Docker; Micro_vm; Remote_ssh ]
let valid_sandbox_profile_strings = Keeper_sandbox_config.valid_sandbox_profile_strings

let network_mode_to_string = function
  | Network_none -> "none"
  | Network_inherit -> "inherit"
;;

let network_mode_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "none" -> Some Network_none
  | "inherit" -> Some Network_inherit
  | _ -> None
;;

(* Issue #8467: Variant SSOT for [network_mode]. *)
let all_network_modes = [ Network_none; Network_inherit ]
let valid_network_mode_strings = List.map network_mode_to_string all_network_modes

let default_network_mode_for_profile = function
  | Docker -> Network_none
  (* Same default as Docker: the guest is a boundary, and opening it is a
     separate decision the keeper TOML states outright. *)
  | Micro_vm -> Network_none
  | Remote_ssh -> Network_inherit
;;

let backend_unimplemented_message profile =
  Printf.sprintf
    "sandbox_profile=%s has no runtime in this build; the call is refused \
     rather than dispatched to another backend"
    (sandbox_profile_to_string profile)
;;

type tree_location =
  | Shared_mount
  | Endpoint_owned

(* A microvm guest owns its tree on the work volume (RFC-0400): the host
   never mounts the playground into it, so every consumer that branches on
   the location reaches that tree through the remote lane. *)
let tree_location_of_profile = function
  | Docker -> Shared_mount
  | Micro_vm -> Endpoint_owned
  | Remote_ssh -> Endpoint_owned
;;
