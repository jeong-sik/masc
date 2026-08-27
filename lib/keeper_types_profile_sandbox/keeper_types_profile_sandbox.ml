type sandbox_profile =
  | Local
    (** Host-process execution. Filesystem scope is bound to
        [<base-path>/.masc/playground/<keeper>/] (see [Playground_paths]).
        Network inherits the server's namespace. Intended for keepers
        whose work stays on local files and does not need container-grade
        isolation. *)
  | Docker
    (** Containerized execution with hardened defaults: cap-drop,
        no-new-privs, read-only rootfs, tmpfs, pids/memory limits.
        Network defaults to [Network_none]. *)
  | Micro_vm
    (** One lightweight virtual machine per container, through Apple's
        [container] CLI on macOS 26+. The guest runs its own Linux kernel,
        so an escape has to cross the hypervisor rather than a shared
        kernel. Measured 2026-08-28 on an M3 Max: 4.0-4.4s to start
        against Docker's 0.6-0.9s, and about 400 MB of host memory per
        running container. Network defaults to [Network_none]. *)
  | Remote_ssh
    (** Execution on a remote host over SSH (Phase 1 lane,
        docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md
        {e 4.2}). Transport-only: the Docker container knobs are not
        reproduced, [network_mode = "none"] is rejected at config load
        ([remote_ssh_no_network_mode]), and the only accepted network
        mode is [Network_inherit] (the default). The runner lands in
        Phase 1 task 6; every dispatch arm fails closed until then. *)

module Sandbox_profile_tla = struct
  type t = sandbox_profile =
    | Local [@tla.symbol "Local"]
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
  | Local -> Keeper_sandbox_config.Local
  | Docker -> Keeper_sandbox_config.Docker
  | Micro_vm -> Keeper_sandbox_config.Micro_vm
  | Remote_ssh -> Keeper_sandbox_config.Remote_ssh

let sandbox_profile_of_config = function
  | Keeper_sandbox_config.Local -> Local
  | Keeper_sandbox_config.Docker -> Docker
  | Keeper_sandbox_config.Micro_vm -> Micro_vm
  | Keeper_sandbox_config.Remote_ssh -> Remote_ssh

let sandbox_profile_to_string profile =
  profile
  |> sandbox_profile_to_config
  |> Keeper_sandbox_config.sandbox_profile_to_string
;;

(** Parse a sandbox profile string. Canonical values are ["local"],
    ["docker"], ["microvm"] and ["remote_ssh"]. *)
let sandbox_profile_of_string raw =
  raw
  |> Keeper_sandbox_config.sandbox_profile_of_string
  |> Option.map sandbox_profile_of_config
;;

(* Issue #8467: Variant SSOT — adding a constructor to [sandbox_profile]
   forces [sandbox_profile_to_string] exhaustiveness AND extends
   [valid_sandbox_profile_strings] so [keeper_schema] picks it up via
   the mirror declared there. *)
let all_sandbox_profiles = [ Local; Docker; Micro_vm; Remote_ssh ]
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
let default_sandbox_profile = Local

let default_network_mode_for_profile = function
  | Local -> Network_inherit
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
