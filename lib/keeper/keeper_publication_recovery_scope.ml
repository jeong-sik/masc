type failure =
  | Registry_entry_not_found of
      { base_path : string
      ; keeper_name : string
      }
  | Registry_entry_unhealthy of Keeper_registry.registry_entry_health

let failure_to_string = function
  | Registry_entry_not_found { base_path; keeper_name } ->
    Printf.sprintf
      "Keeper publication recovery registry entry is not present: base_path=%S keeper=%S"
      base_path
      keeper_name
  | Registry_entry_unhealthy health ->
    Printf.sprintf
      "Keeper publication recovery registry entry is unhealthy: %s"
      (Keeper_registry.registry_entry_validation_error_to_string health)
;;

type turn_resources =
  { entry : Keeper_registry.registry_entry
  ; publication_recovery :
      Keeper_publication_recovery_availability.turn_context
  }

let resolve_turn_resources ~provider ~base_path ~keeper_name =
  match Keeper_registry.get_with_health ~base_path keeper_name with
  | None -> Error (Registry_entry_not_found { base_path; keeper_name })
  | Some (entry, Keeper_registry.Healthy) ->
    Ok
      { entry
      ; publication_recovery = { provider; keeper_name = entry.name }
      }
  | Some (_, health) -> Error (Registry_entry_unhealthy health)
;;
