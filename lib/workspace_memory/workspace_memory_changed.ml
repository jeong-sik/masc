type subscription = { callback : directory:string -> unit }

let mutex = Stdlib.Mutex.create ()
let subscriptions : subscription list ref = ref []

let subscribe callback =
  let subscription = { callback } in
  Stdlib.Mutex.protect mutex (fun () ->
    subscriptions := subscription :: !subscriptions);
  fun () ->
    Stdlib.Mutex.protect mutex (fun () ->
      subscriptions := List.filter (fun current -> current != subscription) !subscriptions)
;;

let written ~directory =
  match Stdlib.Mutex.protect mutex (fun () -> !subscriptions) with
  | [] -> ()
  | current ->
      List.iter (fun subscription ->
        match subscription.callback ~directory with
        | () -> ()
        | exception exn ->
            (* This is a non-yielding after-write notification. A subscriber's
               cancellation must not replace a commit outcome owned elsewhere;
               the writer's next suspension still observes its cancellation. *)
            (match Log.Server.warn "workspace memory change subscriber failed: %s"
              (Printexc.exn_slot_name exn) with
             | () -> ()
             | exception _ -> ())) current
;;
