type change =
  | Workspace of {
      base_path : string;
      payload : Sse_event.Types.dashboard_observation_changed_payload;
    }
  | Process of Sse_event.Types.dashboard_observation_topic

type subscription = { callback : change -> unit }
let mutex = Stdlib.Mutex.create ()
let subscriptions : subscription list ref = ref []

let subscribe callback =
  let subscription = { callback } in
  Stdlib.Mutex.protect mutex (fun () -> subscriptions := subscription :: !subscriptions);
  fun () -> Stdlib.Mutex.protect mutex (fun () ->
    subscriptions := List.filter (fun current -> current != subscription) !subscriptions)
;;

let notify change =
  let current = Stdlib.Mutex.protect mutex (fun () -> !subscriptions) in
  match current with
  | [] -> ()
  | _ :: _ ->
      List.iter (fun subscription ->
        match subscription.callback change with
        | () -> ()
        | exception exn ->
            (* The write outcome belongs to the store. A subscriber's
               cancellation cannot replace it; the writer's next suspension
               still observes the writer's own cancellation. *)
            (match Log.Server.warn "dashboard commit subscriber failed: %s"
              (Printexc.exn_slot_name exn) with
             | () -> ()
             | exception _ -> ())) current
;;

let written ~base_path ~scope topic =
  notify (Workspace { base_path; payload = { topic; scope } })
;;

let process_written topic = notify (Process topic)
;;
