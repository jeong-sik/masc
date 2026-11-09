(** The claims on a work volume as scripts and argv: where the claims marker
    lives in the volume, which claimant names are valid, the add, release and
    read scripts that edit the marker, and the argv of the helper guest that
    runs them.

    [Keeper_sandbox_microvm] includes this module. *)

val volume_claims_marker_name : string

val claims_guest_root : string

val volume_claimant_env_var : string

val volume_claim_helper_name : keeper_name:string -> string

val valid_volume_claimant : string -> bool

val volume_claim_add_script_with : marker:string -> string

val volume_claim_release_script_with : marker:string -> string

val volume_claims_read_script_with : marker:string -> string

val apple_volume_claims_read_argv :
  keeper_name:string -> volume_name:string -> image:string -> string list

val apple_volume_claim_add_argv :
  keeper_name:string -> volume_name:string -> image:string -> claimant:string -> string list

val apple_volume_claim_release_argv :
  keeper_name:string -> volume_name:string -> image:string -> claimant:string -> string list
