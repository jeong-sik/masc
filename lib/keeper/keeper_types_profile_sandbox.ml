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
        Network defaults to [Network_none]; repo CLI identity
        dispatcher (see [Agent_tool_execute_command_semantics.stages_target_repo_commands])
        uses network egress plus read-only mounts from the selected
        root/keeper repo CLI identity bundle for the duration of a repo-scoped
        command. *)

module Sandbox_profile_tla = struct
  type t = sandbox_profile =
    | Local [@tla.symbol "Local"]
    | Docker [@tla.symbol "Docker"]
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

let sandbox_profile_of_config = function
  | Keeper_sandbox_config.Local -> Local
  | Keeper_sandbox_config.Docker -> Docker

let sandbox_profile_to_string profile =
  profile
  |> sandbox_profile_to_config
  |> Keeper_sandbox_config.sandbox_profile_to_string
;;

let legacy_reserved_cascade_names =
  [ "local_only"; "local_recovery"; "tool_use_strict" ]
;;

let reserved_cascade_names =
  List.sort_uniq
    String.compare
    (legacy_reserved_cascade_names
     @ Keeper_config.phase_routing_cascade_names
     @ [ Keeper_config.default_cascade_name ()
       ; Keeper_config.tool_required_cascade_name
       ])
;;

(** Parse a sandbox profile string. Canonical values are ["local"] and
    ["docker"]. *)
let sandbox_profile_of_string raw =
  raw
  |> Keeper_sandbox_config.sandbox_profile_of_string
  |> Option.map sandbox_profile_of_config
;;

(* Issue #8467: Variant SSOT — adding a constructor to [sandbox_profile]
   forces [sandbox_profile_to_string] exhaustiveness AND extends
   [valid_sandbox_profile_strings] so [keeper_schema] picks it up via
   the mirror declared there. *)
let all_sandbox_profiles = [ Local; Docker ]
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
  (* Repo CLI identity dispatch in Docker upgrades to Network_inherit at runtime
     via Agent_tool_execute_command_semantics.stages_target_repo_commands; that upgrade is not
     visible here because it's a per-command decision, not a profile
     default. *)
;;
