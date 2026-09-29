let boot_refusal ~base_path (meta : Keeper_meta_contract.keeper_meta) =
  match meta.Keeper_meta_contract.sandbox_profile with
  | Keeper_types_profile_sandbox.Remote_ssh -> None
  | Keeper_types_profile_sandbox.Docker | Keeper_types_profile_sandbox.Micro_vm ->
    (match Keeper_sandbox_image_resolver.for_keeper ~base_path meta with
     | Ok (_ : Keeper_sandbox_image_catalog.pinned) -> None
     | Error error -> Some error)
;;
