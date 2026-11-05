type event =
  { keepers_dir : string
  ; keeper_id : string
  }

type subscription = { callback : event -> unit }

(* Registration can happen outside Eio. The lock guards only the list; no
   callback runs under it. *)
let registry_mutex = Stdlib.Mutex.create ()
let subscriptions : subscription list ref = ref []

let subscribe callback =
  let subscription = { callback } in
  Stdlib.Mutex.protect registry_mutex (fun () ->
    subscriptions := subscription :: !subscriptions);
  fun () ->
    Stdlib.Mutex.protect registry_mutex (fun () ->
      subscriptions := List.filter (fun current -> current != subscription) !subscriptions)
;;

(* Every caller has already committed its write, and several still have
   bookkeeping to do after this call (a config journal to clear, an Owner
   command to answer). A subscriber belongs to another lifecycle, so whatever
   it raises, a cancellation included, is reported like any failure; the
   caller's next suspension point still sees a cancellation of its own fiber.
   Subscribers must not yield, so they cannot observe one here. *)
let notify current event =
  List.iter
    (fun subscription ->
       match subscription.callback event with
       | () -> ()
       | exception exn ->
         Log.Keeper.warn ~keeper_name:event.keeper_id
           "memory health input subscriber failed keepers_dir=%s: %s"
           event.keepers_dir (Printexc.to_string exn))
    current
;;

let written ~keepers_dir ~keeper_id =
  match Stdlib.Mutex.protect registry_mutex (fun () -> !subscriptions) with
  | [] -> ()
  | current ->
    (match Unix.realpath keepers_dir with
     | keepers_dir -> notify current { keepers_dir; keeper_id }
     | exception Unix.Unix_error (error, _, _) ->
       Log.Keeper.warn ~keeper_name:keeper_id
         "memory health input written under %s, which no longer resolves: %s"
         keepers_dir (Unix.error_message error))
;;
