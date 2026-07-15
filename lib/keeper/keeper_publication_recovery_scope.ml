type failure =
  | Registry_not_provided
  | Registry_entry_not_found of
      { base_path : string
      ; keeper_name : string
      }
  | Registry_entry_unhealthy of Keeper_registry.registry_entry_health
  | Lane_open_failed of Fs_compat.publication_recovery_lane_open_error
  | Access_already_attached
  | Access_not_attached
  | Body_and_detach_failed of
      { body : exn
      ; body_backtrace : Printexc.raw_backtrace
      ; detach : failure
      }

exception Scope_failed of failure
exception Scope_detach_failed_on_cancellation of exn * failure

let rec failure_to_string = function
  | Registry_not_provided ->
    "publication recovery registry is not present in this Keeper runtime context"
  | Registry_entry_not_found { base_path; keeper_name } ->
    Printf.sprintf
      "Keeper publication recovery registry entry is not present: base_path=%S keeper=%S"
      base_path
      keeper_name
  | Registry_entry_unhealthy health ->
    Printf.sprintf
      "Keeper publication recovery registry entry is unhealthy: %s"
      (Keeper_registry.registry_entry_validation_error_to_string health)
  | Lane_open_failed error ->
    Fs_compat.publication_recovery_lane_open_error_to_string error
  | Access_already_attached ->
    "publication recovery access is already attached to this Keeper lane"
  | Access_not_attached ->
    "publication recovery access is not attached to this Keeper lane"
  | Body_and_detach_failed { body; detach; _ } ->
    Printf.sprintf
      "Keeper lane body failed and publication recovery access could not detach: body=%s; detach=%s"
      (Printexc.to_string body)
      (failure_to_string detach)
;;

type turn_resources =
  { entry : Keeper_registry.registry_entry
  ; registry : Fs_compat.publication_recovery_registry
  ; access : Fs_compat.publication_recovery_access
  }

let resolve_turn_resources ~registry ~base_path ~keeper_name =
  match registry with
  | None -> Error Registry_not_provided
  | Some registry ->
    (match Keeper_registry.get_with_health ~base_path keeper_name with
     | None ->
       Error (Registry_entry_not_found { base_path; keeper_name })
     | Some (entry, Keeper_registry.Healthy) ->
       (match Keeper_registry.publication_recovery_access entry with
        | None -> Error Access_not_attached
        | Some access -> Ok { entry; registry; access })
     | Some (_, health) -> Error (Registry_entry_unhealthy health))
;;

let detach entry =
  match Keeper_registry.detach_publication_recovery_access entry with
  | Ok () -> Ok ()
  | Error Keeper_registry.Publication_recovery_not_attached ->
    Error Access_not_attached
;;

let run_attached ~entry ~access body =
  match Keeper_registry.attach_publication_recovery_access entry access with
  | Error Keeper_registry.Publication_recovery_already_attached ->
    raise (Scope_failed Access_already_attached)
  | Ok () ->
    (match body () with
     | value ->
       (match detach entry with
        | Ok () -> value
        | Error failure -> raise (Scope_failed failure))
     | exception (Eio.Cancel.Cancelled reason as cancellation) ->
       let backtrace = Printexc.get_raw_backtrace () in
       (match detach entry with
        | Ok () -> Printexc.raise_with_backtrace cancellation backtrace
        | Error failure ->
          Printexc.raise_with_backtrace
            (Eio.Cancel.Cancelled
               (Scope_detach_failed_on_cancellation (reason, failure)))
            backtrace)
     | exception body ->
       let body_backtrace = Printexc.get_raw_backtrace () in
       (match detach entry with
        | Ok () -> Printexc.raise_with_backtrace body body_backtrace
        | Error failure ->
          raise
            (Scope_failed
               (Body_and_detach_failed
                  { body; body_backtrace; detach = failure }))))
;;

let with_lane_scope ~registry ~entry body =
  match registry with
  | None -> raise (Scope_failed Registry_not_provided)
  | Some registry ->
    (match
       Fs_compat.await_publication_recovery_lane_reconciliation
         ~registry
         ~owner:entry.Keeper_registry.name
     with
     | Error error -> raise (Scope_failed (Lane_open_failed error))
     | Ok () ->
       (match
          Fs_compat.with_publication_recovery_lane
            ~registry
            ~owner:entry.Keeper_registry.name
            (fun access -> run_attached ~entry ~access body)
        with
        | Ok value -> value
        | Error error -> raise (Scope_failed (Lane_open_failed error))))
;;

let () =
  Printexc.register_printer (function
    | Scope_failed failure -> Some (failure_to_string failure)
    | Scope_detach_failed_on_cancellation (reason, failure) ->
      Some
        (Printf.sprintf
           "publication recovery detach failed during cancellation: reason=%s failure=%s"
           (Printexc.to_string reason)
           (failure_to_string failure))
    | _ -> None)
;;
