(** Text form of the rows and errors of publication recovery access: an
    owner, the rows of owner discovery and inventory, and the errors of
    validation, transition, discovery, inspection, reconciliation, lane
    opening and lane release each print as a string.

    This module is private to [fs_compat_internal] and has no interface file.
    [Publication_recovery_access] includes it. *)

open Publication_recovery_access_model

let validation_error_to_string = Core.validation_error_to_string
let transition_error_to_string = Core.transition_error_to_string

let owner_to_string = Core.owner_to_string

let owner_discovery_row_to_string = function
  | Discovered_owner owner ->
    Printf.sprintf "discovered_owner(%S)" (owner_to_string owner)
  | Invalid_owner_name name ->
    Printf.sprintf "invalid_owner_name(%S)" name
;;

let owner_inventory_row_to_string = function
  | Valid_owner owner ->
    Printf.sprintf "valid_owner(%S)" (owner_to_string owner)
  | Unexpected_owner_kind { owner; kind } ->
    Format.asprintf
      "unexpected_owner_kind(%S,%a)"
      (owner_to_string owner)
      Eio.File.Stat.pp_kind
      kind
  | Missing_owner_entry owner ->
    Printf.sprintf "missing_owner_entry(%S)" (owner_to_string owner)
  | Owner_entry_unavailable { owner; error } ->
    Printf.sprintf
      "owner_entry_unavailable(%S,%s)"
      (owner_to_string owner)
      (Core.transition_error_to_string error)
  | Owner_inventory_cancelled { owner; reason; _ } ->
    Printf.sprintf
      "owner_inventory_cancelled(%S,%s)"
      (owner_to_string owner)
      (Printexc.to_string reason)
  | Owner_inventory_crashed { owner; exception_; _ } ->
    Printf.sprintf
      "owner_inventory_crashed(%S,%s)"
      (owner_to_string owner)
      (Printexc.to_string exception_)
;;

let discovery_failure_to_string = function
  | Registry_discovery_failed error ->
    Core.transition_error_to_string error
  | Registry_discovery_cancelled { reason; _ } ->
    Printf.sprintf
      "publication recovery registry discovery cancelled: %s"
      (Printexc.to_string reason)
  | Registry_discovery_crashed { exception_; _ } ->
    Printf.sprintf
      "publication recovery registry discovery crashed: %s"
      (Printexc.to_string exception_)
;;

let discovery_error_to_string = function
  | Registry_discovery_in_progress ->
    "publication recovery registry discovery is already in progress"
  | Registry_discovery_terminal failure ->
    discovery_failure_to_string failure
;;

let owner_block_to_string = function
  | Owner_inventory_block row -> owner_inventory_row_to_string row
  | Owner_reconciliation_block report -> Reconciler.report_to_string report
  | Owner_reconciliation_crash { owner; exception_; _ } ->
    Printf.sprintf
      "owner_reconciliation_crash(%S,%s)"
      (owner_to_string owner)
      (Printexc.to_string exception_)
  | Owner_reconciliation_cancelled_block { owner; reason; _ } ->
    Printf.sprintf
      "owner_reconciliation_cancelled(%S,%s)"
      (owner_to_string owner)
      (Printexc.to_string reason)
;;

let inspection_error_to_string = function
  | Inspection_owner_in_progress owner ->
    Printf.sprintf
      "publication recovery owner inspection is already in progress for %S"
      (owner_to_string owner)
  | Inspection_owner_already_terminal block ->
    Printf.sprintf
      "publication recovery owner was already terminal before inspection: %s"
      (owner_block_to_string block)
;;

let reconciliation_error_to_string = function
  | Owner_inventory_pending owner ->
    Printf.sprintf
      "publication recovery owner inspection is required before reconciling owner %S"
      (owner_to_string owner)
  | Owner_inventory_in_progress owner ->
    Printf.sprintf
      "publication recovery owner inspection is in progress before reconciling owner %S"
      (owner_to_string owner)
  | Owner_reconciliation_not_required owner ->
    Printf.sprintf
      "publication recovery owner %S has no recovery obligation"
      (owner_to_string owner)
  | Owner_reconciliation_in_progress owner ->
    Printf.sprintf
      "publication recovery reconciliation is already in progress for owner %S"
      (owner_to_string owner)
  | Owner_inventory_prevents_reconciliation row ->
    Printf.sprintf
      "owner inventory prevents publication recovery reconciliation: %s"
      (owner_inventory_row_to_string row)
  | Owner_reconciliation_crashed { owner; exception_; _ } ->
    Printf.sprintf
      "publication recovery reconciliation crashed for owner %S: %s"
      (owner_to_string owner)
      (Printexc.to_string exception_)
  | Owner_reconciliation_cancelled { owner; reason; _ } ->
    Printf.sprintf
      "publication recovery reconciliation was internally cancelled for owner %S: %s"
      (owner_to_string owner)
      (Printexc.to_string reason)
;;

let lane_open_error_to_string = function
  | Invalid_owner error -> Core.validation_error_to_string error
  | Reconciliation_blocked block ->
    Printf.sprintf
      "publication recovery reconciliation blocks this owner: %s"
      (owner_block_to_string block)
  | Store_failed error -> Core.transition_error_to_string error
;;

let registry_error_to_string = Core.transition_error_to_string
;;

let lane_release_failure_to_string
      (failure : lane_release_failure)
  =
  Printf.sprintf
    "%s backtrace=%s"
    (Core.failure_to_string failure.failure)
    (Printexc.raw_backtrace_to_string failure.backtrace)
;;
