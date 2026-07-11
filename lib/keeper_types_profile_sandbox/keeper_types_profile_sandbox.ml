type sandbox_profile = Keeper_sandbox_config.sandbox_profile =
  | Local
    (** Host-process execution. Filesystem scope is bound to
        [<base-path>/.masc/playground/<keeper>/] (see [Playground_paths]).
        Network uses the host namespace explicitly. Intended for keepers
        whose work stays on local files and does not need container-grade
        isolation. *)
  | Docker
    (** Containerized execution with hardened defaults: cap-drop,
        no-new-privs, read-only rootfs, tmpfs, pids/memory limits.
        Network defaults to [Network_none]. Host networking is never inferred
        from a command; it requires the explicit [Network_host] policy. *)

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
  | Network_host [@tla.symbol "Network_host"]
[@@deriving tla]

let sandbox_profile_to_string =
  Keeper_sandbox_config.sandbox_profile_to_string

(** Parse a sandbox profile string. Canonical values are ["local"] and
    ["docker"]. *)
let sandbox_profile_of_string raw =
  Keeper_sandbox_config.sandbox_profile_of_string raw
;;

(* Issue #8467: Variant SSOT — adding a constructor to [sandbox_profile]
   forces [sandbox_profile_to_string] exhaustiveness AND extends
   [valid_sandbox_profile_strings] so [keeper_schema] picks it up via
   the mirror declared there. *)
let all_sandbox_profiles = Keeper_sandbox_config.all_sandbox_profiles
let valid_sandbox_profile_strings = Keeper_sandbox_config.valid_sandbox_profile_strings

let network_mode_to_string = function
  | Network_none -> "none"
  | Network_host -> "host"
;;

let network_mode_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "none" -> Some Network_none
  | "host" -> Some Network_host
  | _ -> None
;;

(* Issue #8467: Variant SSOT for [network_mode]. *)
let all_network_modes = [ Network_none; Network_host ]
let valid_network_mode_strings = List.map network_mode_to_string all_network_modes
let default_sandbox_profile = Keeper_sandbox_config.default_sandbox_profile

let default_network_mode_for_profile = function
  | Local -> Network_host
  | Docker -> Network_none
;;

let validate_network_mode_for_profile ~sandbox_profile ~network_mode =
  match sandbox_profile, network_mode with
  | Local, Network_host | Docker, (Network_none | Network_host) -> Ok ()
  | Local, Network_none ->
    Error
      "network_mode=none is only enforceable for sandbox_profile=docker; local execution uses the host network"
;;

type sandbox_container_kind =
  | Sandbox_oneshot
  | Sandbox_turn

let sandbox_container_kind_to_string = function
  | Sandbox_oneshot -> "oneshot"
  | Sandbox_turn -> "turn"
;;

let all_sandbox_container_kinds = [ Sandbox_oneshot; Sandbox_turn ]

let valid_sandbox_container_kind_strings =
  List.map sandbox_container_kind_to_string all_sandbox_container_kinds
;;

let sandbox_container_kind_of_string raw =
  let normalized = String.lowercase_ascii (String.trim raw) in
  List.find_opt
    (fun kind -> String.equal normalized (sandbox_container_kind_to_string kind))
    all_sandbox_container_kinds
;;

type sandbox_stop_scope =
  | Stop_kind of sandbox_container_kind
  | Stop_all

let sandbox_stop_scope_to_string = function
  | Stop_kind kind -> sandbox_container_kind_to_string kind
  | Stop_all -> "all"
;;

let all_sandbox_stop_scopes =
  List.map (fun kind -> Stop_kind kind) all_sandbox_container_kinds @ [ Stop_all ]
;;

let sandbox_stop_scope_of_string raw =
  let normalized = String.lowercase_ascii (String.trim raw) in
  List.find_opt
    (fun scope -> String.equal normalized (sandbox_stop_scope_to_string scope))
    all_sandbox_stop_scopes
;;

let valid_sandbox_stop_scope_strings =
  List.map sandbox_stop_scope_to_string all_sandbox_stop_scopes
;;

(* RFC vision-delegation §2.4 — persisted mechanism-selection axis. Decides how a
   keeper handles image input, resolved independently of the live runtime
   assignment so two identical turns resolve identically (RFC-0265 §3.4
   determinism). Lives here (not keeper_meta_contract) so [keeper_profile_defaults]
   can reference it without a dependency cycle — same layering as [network_mode].
   Mirrors [network_mode]: closed variant, [_of_string] returns [option]
   (unknown -> [None], fail-closed), SSOT lists. *)
(* No [@@deriving tla]: unlike [network_mode]/[sandbox_profile] this policy is
   not referenced by any TLA+ spec, and a second module-level [to_tla_symbol]
   deriver would collide with [network_mode]'s. *)
type multimodal_policy =
  | Mm_delegate
    (* §2.3: evict images to the artifact store at ingestion and read them via
       the analyze_image tool; main history stays text-only. *)
  | Mm_reroute (* RFC-0265: reroute the whole turn to a vision-capable runtime. *)
  | Mm_inherit
    (* follow the workspace default (currently Reroute). Safe-by-default for
       keepers that predate this field — a missing TOML/JSON key parses here. *)

let multimodal_policy_to_string = function
  | Mm_delegate -> "delegate"
  | Mm_reroute -> "reroute"
  | Mm_inherit -> "inherit"
;;

let multimodal_policy_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "delegate" -> Some Mm_delegate
  | "reroute" -> Some Mm_reroute
  | "inherit" -> Some Mm_inherit
  | _ -> None
;;

(* Variant SSOT: adding a constructor forces [multimodal_policy_to_string]
   exhaustiveness and extends [valid_multimodal_policy_strings] that schema and
   parsers mirror. *)
let all_multimodal_policies = [ Mm_delegate; Mm_reroute; Mm_inherit ]

let valid_multimodal_policy_strings =
  List.map multimodal_policy_to_string all_multimodal_policies
;;

(* Safe-by-default: a keeper with no explicit policy inherits today's behaviour
   (RFC-0265 reroute), so Phase 2 is a no-op until an operator opts in. *)
let default_multimodal_policy = Mm_inherit
