open Keeper_approval_queue_rules
open Keeper_approval_queue_projection
open Keeper_approval_queue_result
open Keeper_approval_queue_registry
open Keeper_approval_queue_persist

(** Read a pending entry by id. Returns [None] if already resolved. *)
let find_pending_entry_unchecked ~id : pending_approval option =
  SMap.find_opt id (Atomic.get pending)
;;

let summary_transition_rejection (entry : pending_approval) =
  match entry.exact_attempt with
  | Exact_unbound -> None
  | Exact_bound binding -> Some (Summary_exact_attempt_bound binding)
;;

let persist_pending_entry_unlocked ~map ~(entry : pending_approval) updated_entry =
  let updated = SMap.add entry.id updated_entry map in
  match
    persist_snapshot_unlocked
      ~base_path:entry.audit_base_path
      ~pending_map:updated
      ~delivery_map:(Atomic.get deliveries)
  with
  | Error _ as error -> error
  | Ok () ->
    Atomic.set pending updated;
    Ok true
;;

let notify_waiting_approval ~source (entry : pending_approval) =
  let report exn =
    Log.Keeper.warn "approval waiting inventory notification failed keeper=%s: %s"
      entry.keeper_name (Printexc.to_string exn) in
  match Keeper_waiting_inventory_broadcast.changed
          ~base_path:entry.audit_base_path ~keeper_name:entry.keeper_name ~source with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    (* The queue is already committed. A subscriber's own cancellation is
       observational; the calling fiber's actual cancellation still wins. *)
    (match Fs_compat.execution_context () with
     | Eio_fiber -> Eio.Fiber.check ()
     | Non_eio -> ());
    report exn
  | exception exn -> report exn
;;

let publish_summary_update ~id =
  let now = Time_compat.now () in
  match find_pending_entry_unchecked ~id with
  | Some updated ->
    notify_waiting_approval ~source:Approval_detail updated;
    record_summary_updated ~now updated
  | None -> ()
;;

let publish_summary_transition ~id = function
  | Ok true ->
    publish_summary_update ~id;
    Ok true
  | Ok false -> Ok false
  | Error error -> Error error
;;

let publish_exact_attempt_transition ~id = function
  | Ok ({ changed = true; _ } as transition) ->
    publish_summary_update ~id;
    Ok transition
  | Ok transition -> Ok transition
  | Error error -> Error error
;;
