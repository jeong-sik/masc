type t =
  | Confined
  | External

let digest_pinned_image image =
  let is_lower_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  in
  match String.rindex_opt image '@' with
  | None -> false
  | Some at ->
    let digest = String.sub image (at + 1) (String.length image - at - 1) in
    String.length digest = 71
    && String.sub digest 0 7 = "sha256:"
    && String.for_all is_lower_hex (String.sub digest 7 64)
;;

let classify ~sandbox_profile ~network_mode ~target =
  match sandbox_profile, network_mode, target with
  | Keeper_types_profile_sandbox.Docker
    , Keeper_types_profile_sandbox.Network_none
    , Masc_exec.Sandbox_target.Docker { image; _ }
    when digest_pinned_image image -> Confined
  | ( Keeper_types_profile_sandbox.Local
    | Keeper_types_profile_sandbox.Docker )
    , (Keeper_types_profile_sandbox.Network_none
      | Keeper_types_profile_sandbox.Network_inherit)
    , (Masc_exec.Sandbox_target.Host | Masc_exec.Sandbox_target.Docker _) -> External
;;

let to_string = function
  | Confined -> "confined"
  | External -> "external"
;;
