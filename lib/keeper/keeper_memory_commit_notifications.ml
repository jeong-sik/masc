type store = Ordinary | Source_bound

type event =
  { keepers_dir : string
  ; keeper_id : string
  ; store : store
  ; revision : int
  }

type subscription = { callback : event -> unit }

(* Registration also happens outside Eio. The protected sections only copy or
   update a small in-memory list; no callbacks or effects run under this lock. *)
let registry_mutex = Stdlib.Mutex.create ()
let subscriptions : subscription list ref = ref []

let subscribe callback =
  let subscription = { callback } in
  Stdlib.Mutex.protect registry_mutex (fun () ->
    subscriptions := subscription :: !subscriptions);
  fun () ->
    Stdlib.Mutex.protect registry_mutex (fun () ->
      subscriptions :=
        List.filter (fun current -> current != subscription) !subscriptions)
;;

let notify_committed event =
  let current =
    Stdlib.Mutex.protect registry_mutex (fun () -> !subscriptions)
  in
  let cancellation = ref None in
  List.iter
    (fun subscription ->
       (* A subscriber is an effect boundary owned by another lifecycle. Its
          failure is not a failure of the snapshot that already committed. *)
       try subscription.callback event with
       | Eio.Cancel.Cancelled _ as exn ->
         let backtrace = Printexc.get_raw_backtrace () in
         if Option.is_none !cancellation then cancellation := Some (exn, backtrace)
       | exn ->
         Log.Keeper.warn
           "memory commit subscriber failed keeper=%s revision=%d: %s"
           event.keeper_id
           event.revision
           (Printexc.to_string exn))
    current;
  match !cancellation with
  | None -> ()
  | Some (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
;;
