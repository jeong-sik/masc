type error =
  | Keeper_absent of Keeper_owner_registry.command_error
  | Owner_refused of Keeper_owner_registry.command_error

(* [true] only when the Owner reports that no Keeper meta exists to number.
   Every other refusal is the Owner failing, not the caller naming nothing. *)
let owner_error_means_absent : Keeper_owner.error -> bool = function
  | Keeper_owner.Reducer_rejected Keeper_owner_reducer.Meta_missing -> true
  | Keeper_owner.Reducer_rejected
      ( Keeper_owner_reducer.Meta_already_exists
      | Keeper_owner_reducer.Owner_stopping
      | Keeper_owner_reducer.Invalid_delta _
      | Keeper_owner_reducer.Keeper_identity_mismatch _
      | Keeper_owner_reducer.Identity_mismatch
      | Keeper_owner_reducer.Snapshot_changed )
  | Keeper_owner.Operation_rejected _
  | Keeper_owner.Store_unavailable _
  | Keeper_owner.Store_fenced _
  | Keeper_owner.Owner_stopping
  | Keeper_owner.Owner_closed -> false
;;

let command_error_means_absent : Keeper_owner_registry.command_error -> bool = function
  (* The inventory holds one Owner per Keeper, so no Owner for the name is the
     same absence [Keeper_delegate_targets] reports as an unknown Keeper. *)
  | Keeper_owner_registry.Command_lookup_failed (Keeper_owner_registry.Owner_not_found _) ->
    true
  | Keeper_owner_registry.Command_lookup_failed
      (Keeper_owner_registry.Owner_initialization_failed owner_error)
  | Keeper_owner_registry.Command_rejected owner_error ->
    owner_error_means_absent owner_error
  | Keeper_owner_registry.Command_lookup_failed
      ( Keeper_owner_registry.Inventory_not_installed _
      | Keeper_owner_registry.Owner_unavailable _
      | Keeper_owner_registry.Inventory_stopping )
  | Keeper_owner_registry.Command_lifecycle_reserved _ -> false
;;

let allocate ~(config : Workspace.config) ~keeper_name =
  match
    Keeper_owner_registry.allocate_turn ~base_path:config.base_path ~keeper_name
  with
  | Ok turn_id -> Ok turn_id
  | Error error ->
    Error
      (if command_error_means_absent error
       then Keeper_absent error
       else Owner_refused error)
;;

let to_core_error ~(config : Workspace.config) ~keeper_name error =
  let command_error =
    match error with
    | Keeper_absent command_error | Owner_refused command_error -> command_error
  in
  Agent_core.Error.Io
    (Agent_core.Error.FileOpFailed
       { op = "allocate keeper turn number"
       ; path = Keeper_types_profile.keeper_meta_path config keeper_name
       ; detail = Keeper_owner_registry.command_error_to_string command_error
       })
;;
