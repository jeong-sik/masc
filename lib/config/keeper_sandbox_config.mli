(** Keeper sandbox configuration contract.

    Neutral SSOT for the profile type, codec, default, and storage shape.
    Keeper TOML resolution lives in [Keeper_types_profile]; this module does
    not parse manifests, execute tools, or start Docker. *)

type sandbox_profile =
  | Local
  | Docker

val sandbox_profile_to_string : sandbox_profile -> string
val sandbox_profile_of_string : string -> sandbox_profile option
val all_sandbox_profiles : sandbox_profile list
val valid_sandbox_profile_strings : string list
val default_sandbox_profile : sandbox_profile

val host_root_rel_of_profile :
  sandbox_profile ->
  string ->
  string
