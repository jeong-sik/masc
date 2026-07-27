open Keeper_lifecycle_admission_durable_types

let active_permit_scope_key : permit Eio.Fiber.key = Eio.Fiber.create_key ()
let active_permit_lease_key : permit_lease Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let inherited_permit_scope_suppressed_key : int Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let without_inherited_permit_scope fn =
  match Eio.Fiber.get active_permit_scope_key with
  | None -> fn ()
  | Some permit ->
    Eio.Fiber.with_binding
      inherited_permit_scope_suppressed_key
      permit.scope_id
      fn
;;

let next_permit_scope = Atomic.make 0

let with_permit_lifecycle permit fn =
  Eio.Mutex.use_rw ~protect:true permit.lifecycle.mutex (fun () ->
    fn permit.lifecycle)
;;

let close_to_reentrant_leases permit =
  with_permit_lifecycle permit (fun lifecycle ->
    lifecycle.open_to_reentrant_leases <- false)
;;

let await_reentrant_leases_drained permit =
  Eio.Condition.loop_no_mutex
    permit.lifecycle.leases_changed
    (fun () ->
       with_permit_lifecycle permit (fun lifecycle ->
         if lifecycle.active_reentrant_leases = 0
         then Some ()
         else None))
;;

let close_and_drain_permit permit =
  Eio.Cancel.protect (fun () ->
    close_to_reentrant_leases permit;
    await_reentrant_leases_drained permit)
;;

let with_active_permit ~base_path ~masc_root ~keeper_name ~evidence fn =
  let scope_id = Atomic.fetch_and_add next_permit_scope 1 in
  let permit =
    { base_path
    ; masc_root
    ; keeper_name
    ; evidence
    ; scope_id
    ; lifecycle =
        { mutex = Eio.Mutex.create ()
        ; leases_changed = Eio.Condition.create ()
        ; open_to_reentrant_leases = true
        ; active_reentrant_leases = 0
        }
    }
  in
  Eio.Fiber.with_binding active_permit_scope_key permit (fun () ->
    Fun.protect
      ~finally:(fun () -> close_and_drain_permit permit)
      (fun () -> fn permit))
;;

let permit_scope_matches (permit : permit) ~masc_root keeper_name =
  (match Eio.Fiber.get inherited_permit_scope_suppressed_key with
   | None -> true
   | Some suppressed_scope_id ->
     not (Int.equal suppressed_scope_id permit.scope_id))
  && String.equal permit.masc_root masc_root
  && String.equal permit.keeper_name keeper_name
  &&
  match Eio.Fiber.get active_permit_scope_key with
  | Some active_permit -> Int.equal active_permit.scope_id permit.scope_id
  | None -> false
;;

let permit_registry_scope_matches (permit : permit) ~base_path keeper_name =
  (match Eio.Fiber.get inherited_permit_scope_suppressed_key with
   | None -> true
   | Some suppressed_scope_id ->
     not (Int.equal suppressed_scope_id permit.scope_id))
  && String.equal permit.base_path base_path
  && String.equal permit.keeper_name keeper_name
  &&
  match Eio.Fiber.get active_permit_scope_key with
  | Some active_permit -> Int.equal active_permit.scope_id permit.scope_id
  | None -> false
;;

let lease_is_live_for_permit permit = function
  | Some lease ->
    lease.live
    && Int.equal lease.permit_scope_id permit.scope_id
  | None -> false
;;

let release_reentrant_lease permit lease =
  let drained =
    with_permit_lifecycle permit (fun lifecycle ->
      if lease.live
      then (
        lease.live <- false;
        lifecycle.active_reentrant_leases <-
          lifecycle.active_reentrant_leases - 1;
        lifecycle.active_reentrant_leases = 0)
      else false)
  in
  if drained
  then Eio.Condition.broadcast permit.lifecycle.leases_changed
;;

let try_with_reentrant_lease permit fn =
  let parent_lease = Eio.Fiber.get active_permit_lease_key in
  let lease =
    { permit_scope_id = permit.scope_id
    ; live = false
    }
  in
  Eio.Fiber.with_binding active_permit_lease_key lease (fun () ->
    Fun.protect
      ~finally:(fun () ->
        Eio.Cancel.protect (fun () ->
          release_reentrant_lease permit lease))
      (fun () ->
         let acquired =
           with_permit_lifecycle permit (fun lifecycle ->
             if
               lifecycle.open_to_reentrant_leases
               || lease_is_live_for_permit permit parent_lease
             then (
               lifecycle.active_reentrant_leases <-
                 lifecycle.active_reentrant_leases + 1;
               lease.live <- true;
               true)
             else false)
         in
         if acquired then Some (fn permit) else None))
;;
