type handle =
  { bus : Agent_sdk.Event_bus.t
  ; inner : Agent_sdk.Event_bus.subscription
  }

let mu = Stdlib.Mutex.create ()
let handles : handle list ref = ref []
let purpose_depths : (string, int) Hashtbl.t = Hashtbl.create 16
let purpose_warned : (string, bool) Hashtbl.t = Hashtbl.create 16

let publish_total_metric = "masc_oas_bus_publish_total"
let publish_block_seconds_metric = "masc_oas_bus_publish_block_seconds_total"

let with_lock f =
  Stdlib.Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock mu) f
;;

let unique_buses handles =
  List.fold_left
    (fun acc handle ->
       if List.exists (fun bus -> bus == handle.bus) acc then acc else handle.bus :: acc)
    []
    handles
;;

let refresh_locked () =
  Hashtbl.clear purpose_depths;
  List.iter
    (fun bus ->
       let stats = Agent_sdk.Event_bus.stats bus in
       List.iter
         (fun (sub : Agent_sdk.Event_bus.subscription_stats) ->
            match sub.purpose with
            | None -> ()
            | Some purpose ->
              let current =
                match Hashtbl.find_opt purpose_depths purpose with
                | Some depth -> depth
                | None -> 0
              in
              Hashtbl.replace purpose_depths purpose (current + sub.depth))
         stats.subscriptions)
    (unique_buses !handles)
;;

let subscribe ~purpose ?(filter = Agent_sdk.Event_bus.accept_all) bus =
  let inner = Agent_sdk.Event_bus.subscribe ~filter ~purpose bus in
  let handle = { bus; inner } in
  with_lock (fun () ->
    handles := handle :: !handles;
    refresh_locked ());
  handle
;;

let drain handle =
  Eio.Fiber.yield ();
  let events = Agent_sdk.Event_bus.drain handle.inner in
  with_lock refresh_locked;
  events
;;

let unsubscribe bus handle =
  Agent_sdk.Event_bus.unsubscribe bus handle.inner;
  with_lock (fun () ->
    handles := List.filter (fun candidate -> candidate != handle) !handles;
    refresh_locked ())
;;

let publish bus event =
  let before = (Agent_sdk.Event_bus.stats bus).total_publish_blocked_seconds in
  Agent_sdk.Event_bus.publish bus event;
  let after = (Agent_sdk.Event_bus.stats bus).total_publish_blocked_seconds in
  Otel_metric_store.inc_counter publish_total_metric ();
  if Float.compare after before > 0
  then Otel_metric_store.inc_counter publish_block_seconds_metric ~delta:(after -. before) ();
  with_lock refresh_locked
;;

let start_sampler ~sw:_ ~clock:_ ?interval_s:_ ?warn_threshold:_ () = ()

module For_testing = struct
  type transition =
    [ `Warn of string * int
    | `Recovered of string * int
    ]

  let current_depth ~purpose =
    with_lock (fun () ->
      match Hashtbl.find_opt purpose_depths purpose with
      | Some depth -> depth
      | None -> -1)
  ;;

  let sample_threshold_transitions ~warn_threshold =
    with_lock (fun () ->
      Hashtbl.fold
        (fun purpose depth acc ->
           let warned =
             match Hashtbl.find_opt purpose_warned purpose with
             | Some value -> value
             | None -> false
           in
           if depth >= warn_threshold && not warned then (
             Hashtbl.replace purpose_warned purpose true;
             `Warn (purpose, depth) :: acc)
           else if depth < warn_threshold && warned then (
             Hashtbl.replace purpose_warned purpose false;
             `Recovered (purpose, depth) :: acc)
           else acc)
        purpose_depths
        [])
  ;;

  let reset () =
    with_lock (fun () ->
      handles := [];
      Hashtbl.clear purpose_depths;
      Hashtbl.clear purpose_warned)
  ;;
end
