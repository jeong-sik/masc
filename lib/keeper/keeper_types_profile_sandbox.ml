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
        Network defaults to [Network_none]; the internal git/gh
        dispatcher (see [Keeper_exec_shell.cmd_targets_git_or_gh])
        uses network egress plus read-only mounts from the selected
        root/keeper GitHub identity bundle for the duration of a git/gh
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

let sandbox_profile_to_string = function
  | Local -> "local"
  | Docker -> "docker"
;;

let reserved_cascade_names =
  List.sort_uniq
    String.compare
    (Keeper_config.phase_routing_cascade_names
     @ [ Keeper_config.tool_use_strict_cascade_name ])
;;

(** Parse a sandbox profile string. Canonical values are ["local"] and
    ["docker"]. Legacy names ["legacy_local"], ["docker_hardened"], and
    ["docker_with_git"] are still accepted for backward compatibility
    with existing keeper JSON/TOML; they map to the new variants and
    [load_keeper_sandbox_profile_with_warning] below emits a warning. *)
let sandbox_profile_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "local" -> Some Local
  | "docker" -> Some Docker
  (* Temporary compatibility layer — remove after all config/state files
     have been migrated to the canonical names. Keep in ONE place so the
     eventual removal is a single diff. *)
  | "legacy_local" -> Some Local
  | "docker_hardened" -> Some Docker
  | "docker_with_git" -> Some Docker
  | _ -> None
;;

(** Same as [sandbox_profile_of_string] but emits a warning when a
    deprecated string is encountered. Call from the boundary that reads
    keeper state/config files so operators see drift in the server log. *)
let sandbox_profile_of_string_with_warning ~source raw =
  let trimmed = String.trim (String.lowercase_ascii raw) in
  (match trimmed with
   | "legacy_local" | "docker_hardened" | "docker_with_git" ->
     Log.Keeper.warn
       "%s: sandbox_profile %S is deprecated, mapped to %S"
       source
       trimmed
       (match trimmed with
        | "legacy_local" -> "local"
        | "docker_hardened" | "docker_with_git" -> "docker"
        | _ -> trimmed)
   | _ -> ());
  sandbox_profile_of_string raw
;;

(* Issue #8467: Variant SSOT — adding a constructor to [sandbox_profile]
   forces [sandbox_profile_to_string] exhaustiveness AND extends
   [valid_sandbox_profile_strings] so [keeper_schema] picks it up via
   the mirror declared there. *)
let all_sandbox_profiles = [ Local; Docker ]
let valid_sandbox_profile_strings = List.map sandbox_profile_to_string all_sandbox_profiles

let network_mode_to_string = function
  | Network_none -> "none"
  | Network_inherit -> "inherit"
;;

let network_mode_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "none" -> Some Network_none
  | "inherit" -> Some Network_inherit
  | "host" ->
    Log.Keeper.warn
      "network_mode=\"host\" is a deprecated alias for \"inherit\"; \
       update TOML to use \"inherit\"";
    Some Network_inherit
  | _ -> None
;;

(* Issue #8467: Variant SSOT for [network_mode]. *)
let all_network_modes = [ Network_none; Network_inherit ]
let valid_network_mode_strings = List.map network_mode_to_string all_network_modes
let default_sandbox_profile = Local

let default_network_mode_for_profile = function
  | Local -> Network_inherit
  | Docker -> Network_none
  (* git/gh dispatch in Docker upgrades to Network_inherit at runtime
     via Keeper_exec_shell.cmd_targets_git_or_gh; that upgrade is not
     visible here because it's a per-command decision, not a profile
     default. *)
;;
