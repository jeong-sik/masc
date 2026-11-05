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

let notify current event =
  let cancellation = ref None in
  List.iter
    (fun subscription ->
       (* A subscriber belongs to another lifecycle. Its failure is not a
          failure of the write that already returned. *)
       try subscription.callback event with
       | Eio.Cancel.Cancelled _ as exn ->
         let backtrace = Printexc.get_raw_backtrace () in
         if Option.is_none !cancellation then cancellation := Some (exn, backtrace)
       | exn ->
         Log.Keeper.warn ~keeper_name:event.keeper_id
           "memory health input subscriber failed keepers_dir=%s: %s"
           event.keepers_dir (Printexc.to_string exn))
    current;
  match !cancellation with
  | None -> ()
  | Some (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
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
