(** Per-owner synchronization for durable Keeper event queues. *)

type resolve_error =
  | Invalid_base_path of string
  | Invalid_keeper_name of string

module Owner_key = struct
  type nonrec t = string * Keeper_id.Keeper_name.t

  let equal (left_base, left_name) (right_base, right_name) =
    String.equal left_base right_base
    && Keeper_id.Keeper_name.equal left_name right_name
  ;;

  let hash (base_path, keeper_name) =
    Hashtbl.hash (base_path, Keeper_id.Keeper_name.to_string keeper_name)
  ;;
end

type t =
  { owner_key : Owner_key.t
  ; eio_gate : Eio.Mutex.t
  ; cross_context_mutex : Stdlib.Mutex.t
  }

module Owner_table = Ephemeron.K1.Make (Owner_key)

(* No fleet-size estimate belongs at this boundary; the table grows from its
   implementation-defined minimum as canonical owners are resolved. Ephemeron
   keys let inactive owners disappear without an arbitrary eviction policy;
   every active caller keeps [owner_key] strongly reachable through [t]. *)
let owners : t Owner_table.t = Owner_table.create 0
let owners_mutex = Stdlib.Mutex.create ()

let resolve_error_to_string = function
  | Invalid_base_path reason -> "invalid event-queue base path: " ^ reason
  | Invalid_keeper_name reason -> reason
;;

let canonical_base_path raw =
  Config_dir_resolver.canonical_base_path raw
  |> Result.map_error (fun error ->
    Invalid_base_path
      (Config_dir_resolver.canonical_base_path_error_to_string error))
;;

let resolve ~base_path ~keeper_name =
  match canonical_base_path base_path, Keeper_id.Keeper_name.of_string keeper_name with
  | Error error, _ -> Error error
  | Ok _, Error reason -> Error (Invalid_keeper_name reason)
  | Ok base_path, Ok keeper_name ->
    let key = base_path, keeper_name in
    Ok
      (Stdlib.Mutex.protect owners_mutex (fun () ->
         match Owner_table.find_opt owners key with
         | Some owner -> owner
         | None ->
           Owner_table.clean owners;
           let owner =
             { owner_key = key
             ; eio_gate = Eio.Mutex.create ()
             ; cross_context_mutex = Stdlib.Mutex.create ()
             }
           in
           Owner_table.add owners key owner;
           owner))
;;

let base_path owner = fst owner.owner_key
let keeper_name owner = snd owner.owner_key

type execution_context =
  | Eio_fiber
  | Non_eio

let execution_context () =
  match Eio.Fiber.check () with
  | () -> Eio_fiber
  | exception Effect.Unhandled _ -> Non_eio
;;

let rec lock_cross_context_cooperatively mutex =
  if Stdlib.Mutex.try_lock mutex
  then ()
  else (
    Eio.Fiber.yield ();
    lock_cross_context_cooperatively mutex)
;;

type 'a lock_outcome =
  | Returned of 'a
  | Raised of exn * Printexc.raw_backtrace

(* Eio [use_ro] is still exclusive; unlike [use_rw], it releases rather than
   poisons the gate when the callback raises. The gate carries no mutable
   resource state of its own, and the shared Stdlib mutex is released by the
   [Fun.protect] finalizer before any callback exception is propagated. *)
let with_eio_lock ~check_after owner f =
  let outcome =
    match
      Eio.Mutex.use_ro owner.eio_gate (fun () ->
        lock_cross_context_cooperatively owner.cross_context_mutex;
        Eio.Cancel.protect (fun () ->
          Fun.protect
            ~finally:(fun () -> Stdlib.Mutex.unlock owner.cross_context_mutex)
            f))
    with
    | value -> Returned value
    | exception exn -> Raised (exn, Printexc.get_raw_backtrace ())
  in
  (* [Cancel.protect] deliberately finishes an acquired persistence
     transaction. Re-check the parent context after both owner locks have been
     released on every outcome so an ordinary exception cannot mask pending
     cancellation. *)
  if check_after then Eio.Fiber.check ();
  match outcome with
  | Returned value -> value
  | Raised (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
;;

let with_lock owner f =
  match execution_context () with
  | Eio_fiber -> with_eio_lock ~check_after:true owner f
  | Non_eio -> Stdlib.Mutex.protect owner.cross_context_mutex f
;;

let with_durable_lock owner f =
  match execution_context () with
  | Eio_fiber -> with_eio_lock ~check_after:false owner f
  | Non_eio -> Stdlib.Mutex.protect owner.cross_context_mutex f
;;
