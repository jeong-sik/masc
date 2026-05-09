(** Implementation: see [oas_bus_instrument.mli].

    Design notes:
    - One global [Stdlib.Mutex] guards the registry. The critical
      section is tiny (a table op + an int ref update) and must be
      safe across OCaml 5 domains (publish can happen from any fiber
      on any domain). Eio.Mutex would deadlock for same-domain
      publishers that re-enter (not expected today but cheap to avoid).
    - Depth is an approximation. It overcounts if an event is dropped
      by OAS (bounded stream full after blocking timeout — today OAS
      blocks, never drops, so this stays accurate) and undercounts
      transiently between [publish]'s increment and the subscriber's
      [drain]. Sustained high values still indicate backpressure.
    - Filters run inside [publish] while holding the registry mutex.
      Filters are pure predicates (per OAS spec) so this is cheap.
    - Gauge writes go through [Prometheus.set_gauge] which takes its
      own mutex; we release the registry mutex before touching it. *)

type tracked =
  { sub : Agent_sdk.Event_bus.subscription
  ; purpose : string
  ; filter : Agent_sdk.Event_bus.filter
  ; depth : int ref
  ; warned_above_threshold : bool ref
  }

type handle = tracked

type transition =
  [ `Warn of string * int
  | `Recovered of string * int
  ]

(* Module-global registry of active tracked subscriptions. Bounded by
   the number of live MASC subscribers (today: ~4). Not a hotspot. *)
let registry : tracked list ref = ref []
let registry_mutex = Stdlib.Mutex.create ()

let with_registry f =
  Stdlib.Mutex.lock registry_mutex;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock registry_mutex) f
;;

(* Metric name constants. Exported implicitly via set_gauge / inc_counter
   calls below — registered in [prometheus.ml:init] for HELP text. *)
let gauge_stream_depth = "masc_oas_bus_subscriber_stream_depth"
let counter_publish_block_seconds = "masc_oas_bus_publish_block_seconds_total"
let counter_publish_total = "masc_oas_bus_publish_total"

let update_gauge_for purpose value =
  Prometheus.set_gauge
    gauge_stream_depth
    ~labels:[ "subscriber_purpose", purpose ]
    (float_of_int value)
;;

let subscribe ~purpose ?(filter = Agent_sdk.Event_bus.accept_all) bus =
  let sub = Agent_sdk.Event_bus.subscribe ~filter bus in
  let t = { sub; purpose; filter; depth = ref 0; warned_above_threshold = ref false } in
  with_registry (fun () -> registry := t :: !registry);
  update_gauge_for purpose 0;
  t
;;

let drain (t : handle) =
  let events = Agent_sdk.Event_bus.drain t.sub in
  let n = List.length events in
  if n > 0
  then (
    let new_depth =
      with_registry (fun () ->
        t.depth := max 0 (!(t.depth) - n);
        !(t.depth))
    in
    update_gauge_for t.purpose new_depth);
  events
;;

let unsubscribe bus (t : handle) =
  with_registry (fun () -> registry := List.filter (fun r -> r != t) !registry);
  (* Zero out the gauge so a stale value doesn't linger after a
     subscriber shuts down. *)
  update_gauge_for t.purpose 0;
  Agent_sdk.Event_bus.unsubscribe bus t.sub
;;

(* Collect subscriptions whose filter accepts [evt] and bump their
   depth. Done under the registry mutex so a concurrent [unsubscribe]
   cannot free the tracked record mid-bump. Filter evaluation is
   cheap (predicate match). *)
let bump_matching_subs (evt : Agent_sdk.Event_bus.event) =
  let updates =
    with_registry (fun () ->
      List.filter_map
        (fun t ->
           if t.filter evt
           then (
             incr t.depth;
             Some (t.purpose, !(t.depth)))
           else None)
        !registry)
  in
  List.iter (fun (purpose, depth) -> update_gauge_for purpose depth) updates
;;

let publish bus (evt : Agent_sdk.Event_bus.event) =
  bump_matching_subs evt;
  Prometheus.inc_counter counter_publish_total ();
  let started = Time_compat.now () in
  Eio_guard.protect
    ~finally:(fun () ->
      let elapsed = Time_compat.now () -. started in
      if elapsed > 0.0
      then Prometheus.inc_counter counter_publish_block_seconds ~delta:elapsed ())
    (fun () -> Agent_sdk.Event_bus.publish bus evt)
;;

let compute_threshold_transitions ~warn_threshold : transition list =
  with_registry (fun () ->
    List.filter_map
      (fun t ->
         let depth = !(t.depth) in
         let above_threshold = depth > warn_threshold in
         let was_above_threshold = !(t.warned_above_threshold) in
         if above_threshold && not was_above_threshold
         then (
           t.warned_above_threshold := true;
           Some (`Warn (t.purpose, depth)))
         else if (not above_threshold) && was_above_threshold
         then (
           t.warned_above_threshold := false;
           Some (`Recovered (t.purpose, depth)))
         else None)
      !registry)
;;

let start_sampler ~sw ~clock ?(interval_s = 5.0) ?(warn_threshold = 200) () =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
         compute_threshold_transitions ~warn_threshold
         |> List.iter (function
           | `Warn (purpose, depth) ->
             Log.Misc.warn
               "oas_bus_instrument: subscriber_purpose=%s depth=%d exceeds \
                warn_threshold=%d — OAS publish may be blocking on bounded Eio.Stream \
                (default buffer 256)"
               purpose
               depth
               warn_threshold
           | `Recovered (purpose, depth) ->
             Log.Misc.info
               "oas_bus_instrument: subscriber_purpose=%s depth=%d recovered below \
                warn_threshold=%d"
               purpose
               depth
               warn_threshold)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn
           "oas_bus_instrument: sampler iteration failed: %s"
           (Printexc.to_string exn));
      Eio.Time.sleep clock interval_s;
      loop ()
    in
    loop ())
;;

module For_testing = struct
  type nonrec transition = transition

  let current_depth ~purpose =
    with_registry (fun () ->
      match List.find_opt (fun t -> t.purpose = purpose) !registry with
      | Some t -> !(t.depth)
      | None -> -1)
  ;;

  let sample_threshold_transitions ~warn_threshold =
    compute_threshold_transitions ~warn_threshold
  ;;

  let reset () = with_registry (fun () -> registry := [])
end
