type t =
  | Confined
  | External

let classify ~sandbox_profile ~network_mode ~target ~containment_verified =
  match sandbox_profile, network_mode, target, containment_verified with
  | Keeper_types_profile_sandbox.Docker
    , Keeper_types_profile_sandbox.Network_none
    , Masc_exec.Sandbox_target.Docker _
    , true -> Confined
  | ( Keeper_types_profile_sandbox.Local
    | Keeper_types_profile_sandbox.Docker )
    , (Keeper_types_profile_sandbox.Network_none
      | Keeper_types_profile_sandbox.Network_inherit)
    , (Masc_exec.Sandbox_target.Host | Masc_exec.Sandbox_target.Docker _)
    , (false | true) -> External
;;

let to_string = function
  | Confined -> "confined"
  | External -> "external"
;;
