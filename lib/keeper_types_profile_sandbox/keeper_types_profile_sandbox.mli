type sandbox_profile = Keeper_sandbox_config.sandbox_profile =
  | Local
  | Docker

module Sandbox_profile_tla : sig
  type t = sandbox_profile =
    | Local [@tla.symbol "Local"]
    | Docker [@tla.symbol "Docker"]
  [@@deriving tla]
end

type network_mode =
  | Network_none [@tla.symbol "Network_none"]
  | Network_host [@tla.symbol "Network_host"]
[@@deriving tla]

val sandbox_profile_to_string : sandbox_profile -> string
val sandbox_profile_of_string : string -> sandbox_profile option
val all_sandbox_profiles : sandbox_profile list
val valid_sandbox_profile_strings : string list
val network_mode_to_string : network_mode -> string
val network_mode_of_string : string -> network_mode option
val all_network_modes : network_mode list
val valid_network_mode_strings : string list
val default_sandbox_profile : sandbox_profile
val default_network_mode_for_profile : sandbox_profile -> network_mode
val validate_network_mode_for_profile :
  sandbox_profile:sandbox_profile ->
  network_mode:network_mode ->
  (unit, string) result
(** Rejects profile/network pairs whose persisted label cannot be enforced.
    Local execution necessarily uses the host network; Docker supports either
    explicit [none] or explicit [host]. *)

(** Typed kinds created by the real on-demand Docker execution paths. *)
type sandbox_container_kind =
  | Sandbox_oneshot
  | Sandbox_turn

val sandbox_container_kind_to_string : sandbox_container_kind -> string
val sandbox_container_kind_of_string : string -> sandbox_container_kind option
val all_sandbox_container_kinds : sandbox_container_kind list
val valid_sandbox_container_kind_strings : string list

(** Typed scope for explicit sandbox stop operations. This lower-level
    contract is shared by schema, producers, and Docker control. *)
type sandbox_stop_scope =
  | Stop_kind of sandbox_container_kind
  | Stop_all

val sandbox_stop_scope_to_string : sandbox_stop_scope -> string
val sandbox_stop_scope_of_string : string -> sandbox_stop_scope option
val all_sandbox_stop_scopes : sandbox_stop_scope list
val valid_sandbox_stop_scope_strings : string list

(** RFC vision-delegation §2.4 — persisted image-handling mechanism axis,
    resolved independently of the live runtime assignment. Same layering as
    {!network_mode} so {!Keeper_types_profile_defaults} can reference it. *)
type multimodal_policy =
  | Mm_delegate  (** evict images at ingestion; read via the analyze_image tool *)
  | Mm_reroute  (** RFC-0265: reroute the whole turn to a vision-capable runtime *)
  | Mm_inherit  (** follow the workspace default (currently reroute); safe default *)

val multimodal_policy_to_string : multimodal_policy -> string

(** [None] on an unrecognised value (fail-closed); callers default to
    {!default_multimodal_policy}. *)
val multimodal_policy_of_string : string -> multimodal_policy option

val all_multimodal_policies : multimodal_policy list
val valid_multimodal_policy_strings : string list
val default_multimodal_policy : multimodal_policy
