(** Keeper error recording (Log + last_error persistence).

    Extracted from keeper_registry.ml (lines 456-506) as part of the
    godfile decomp campaign. The final CAS write to [last_error] goes through
    [Keeper_registry.set_last_error_entry] so this module does not need
    to know about the central Atomic. *)

let record_common ?details name err persist =
  (match details with
   | Some details ->
     Log.Keeper.emit
       Log.Error
       ~details
       (Printf.sprintf "registry: recording error name=%s error=%s" name err)
   | None ->
     Log.Keeper.error "registry: recording error name=%s error=%s" name err);
  persist ()
;;

let record ~base_path ?details name err =
  record_common ?details name err (fun () ->
    Keeper_registry.set_last_error_entry ~base_path ~name err)
;;

let record_exact ?details (entry : Keeper_registry.registry_entry) err =
  record_common ?details entry.name err (fun () ->
    match Keeper_registry.set_last_error_exact entry err with
    | Keeper_registry.Exact_updated -> ()
    | Keeper_registry.Exact_update_missing ->
      Log.Keeper.warn
        "registry: exact error record skipped because lane is no longer registered name=%s"
        entry.name
    | Keeper_registry.Exact_update_replaced ->
      Log.Keeper.warn
        "registry: exact error record retained newer same-name lane name=%s"
        entry.name
    | Keeper_registry.Exact_update_invalid validation_error ->
      Log.Keeper.warn
        "registry: exact error record validation failed name=%s error=%s"
        entry.name
        (Keeper_registry.registry_entry_validation_error_to_string validation_error))
;;

let record_exact_for_lifecycle
      token
      ?details
      (entry : Keeper_registry.registry_entry)
      err
  =
  record_common ?details entry.name err (fun () ->
    match
      Keeper_registry.update_entry_exact_for_lifecycle token entry (fun current ->
        { current with last_error = Some err })
    with
    | Keeper_registry.Exact_updated -> ()
    | Keeper_registry.Exact_update_missing ->
      Log.Keeper.warn
        "registry: lifecycle exact error record skipped because lane is no longer registered name=%s"
        entry.name
    | Keeper_registry.Exact_update_replaced ->
      Log.Keeper.warn
        "registry: lifecycle exact error record retained newer same-name lane name=%s"
        entry.name
    | Keeper_registry.Exact_update_invalid validation_error ->
      Log.Keeper.warn
        "registry: lifecycle exact error record validation failed name=%s error=%s"
        entry.name
        (Keeper_registry.registry_entry_validation_error_to_string validation_error))
;;
