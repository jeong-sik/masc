(** Mutex-backed Otel_metric_store metric store. *)

type label = string * string

let metric_key = Otel_metric_key.metric_key

type metric_type =
  | Counter
  | Gauge
  | Histogram

type metric =
  { name : string
  ; help : string
  ; metric_type : metric_type
  ; mutable value : float
  ; labels : label list
  }

(** Metrics are shared by fibers/domains, so reads and writes are serialized
    through [Stdlib.Mutex]. It is available during module initialization and
    protects both registration and float updates. *)
let metrics : (string, metric) Hashtbl.t = Hashtbl.create 64
let metrics_mutex = Stdlib.Mutex.create ()

(* #10682: capture the caller stack for rare EDEADLK re-entry failures so the
   next diagnostic render can name the offending metric path. *)
let last_deadlock_backtrace : string option Atomic.t = Atomic.make None

let with_lock f =
  let bt0 = Printexc.get_callstack 64 in
  (try Stdlib.Mutex.lock metrics_mutex with
   | Sys_error msg as exn ->
     let trace = Printexc.raw_backtrace_to_string bt0 in
     let dump = Printf.sprintf "Otel_metric_store.with_lock: %s\nCaller stack:\n%s" msg trace in
     Atomic.set last_deadlock_backtrace (Some dump);
     Log.Metrics.error "Otel_metric_store mutex deadlock: %s" dump;
     raise exn);
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock metrics_mutex) f
;;

let last_deadlock_backtrace_for_test () = Atomic.get last_deadlock_backtrace

(** Best-effort wrapper: never crash the caller fiber for a metrics update.
    Metrics are advisory; losing one sample must not take down the OTel tick
    fiber or the keeper turn. *)
let best_effort f =
  try f () with
  | exn ->
    Log.Metrics.warn "Otel_metric_store update failed (non-fatal): %s"
      (Printexc.to_string exn)
;;

let register_counter ~name ~help ?(labels = []) () =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      if not (Hashtbl.mem metrics key)
      then
        Hashtbl.add metrics key { name; help; metric_type = Counter; value = 0.0; labels }))
;;

(* Zero-fill declaration: registers the unlabeled 0-cell at module-init time
   and hands the name back so `let metric_x = declare_counter "..."` keeps
   the constant shape.  Counters only: a counter that has not fired IS 0,
   so exporting the 0-cell removes the absence-vs-zero ambiguity in
   dashboards (a gauge that was never set has no honest value — gauges and
   histograms stay lazy). *)
let declare_counter name =
  register_counter ~name ~help:name ();
  name
;;

let register_gauge ~name ~help ?(labels = []) () =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      if not (Hashtbl.mem metrics key)
      then Hashtbl.add metrics key { name; help; metric_type = Gauge; value = 0.0; labels }))
;;

let register_histogram ~name ~help ?(labels = []) () =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      if not (Hashtbl.mem metrics key)
      then
        Hashtbl.add metrics key { name; help; metric_type = Histogram; value = 0.0; labels }))
;;

let histogram_buckets : (string, float list) Hashtbl.t = Hashtbl.create 16

let register_histogram_buckets name bounds =
  best_effort (fun () ->
    with_lock (fun () -> Hashtbl.replace histogram_buckets name bounds))
;;

let inc_counter name ?(labels = []) ?(delta = 1.0) () =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      match Hashtbl.find_opt metrics key with
      | Some m -> m.value <- m.value +. delta
      | None ->
        Hashtbl.add
          metrics
          key
          { name; help = name; metric_type = Counter; value = delta; labels }))
;;

let set_gauge name ?(labels = []) value =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      match Hashtbl.find_opt metrics key with
      | Some m -> m.value <- value
      | None ->
        Hashtbl.add metrics key { name; help = name; metric_type = Gauge; value; labels }))
;;

let inc_gauge name ?(labels = []) ?(delta = 1.0) () =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      match Hashtbl.find_opt metrics key with
      | Some m -> m.value <- m.value +. delta
      | None ->
        Hashtbl.add
          metrics
          key
          { name; help = name; metric_type = Gauge; value = delta; labels }))
;;

let dec_gauge name ?(labels = []) ?(delta = 1.0) () =
  inc_gauge name ~labels ~delta:(-.delta) ()
;;

let get_metric_value name ?(labels = []) () =
  let key = metric_key name labels in
  with_lock (fun () -> Hashtbl.find_opt metrics key |> Option.map (fun m -> m.value))
;;

let metric_value_or_zero name ?(labels = []) () =
  get_metric_value name ~labels () |> Option.value ~default:0.0
;;

let metric_total name =
  with_lock (fun () ->
    Hashtbl.fold
      (fun _ (m : metric) acc -> if String.equal m.name name then acc +. m.value else acc)
      metrics
      0.0)
;;

let snapshot () =
  with_lock (fun () ->
    Hashtbl.fold
      (fun _ (m : metric) acc ->
         { name = m.name
         ; help = m.help
         ; metric_type = m.metric_type
         ; value = m.value
         ; labels = m.labels
         }
         :: acc)
      metrics
      [])
;;

let observe_histogram name ?(labels = []) value =
  best_effort (fun () ->
    let key = metric_key name labels in
    let count_key = metric_key (name ^ "_count") labels in
    with_lock (fun () ->
      (match Hashtbl.find_opt metrics key with
       | Some m -> m.value <- m.value +. value
       | None ->
         Hashtbl.add
           metrics
           key
           { name; help = name; metric_type = Histogram; value; labels });
      (match Hashtbl.find_opt metrics count_key with
       | Some m -> m.value <- m.value +. 1.0
       | None ->
         Hashtbl.add
           metrics
           count_key
           { name = name ^ "_count"
           ; help = name ^ " observation count"
           ; metric_type = Counter
           ; value = 1.0
           ; labels
           });
      (match Hashtbl.find_opt histogram_buckets name with
       | Some bounds ->
         List.iter
           (fun bound ->
              let le = Printf.sprintf "%g" bound in
              let bucket_labels = ("le", le) :: labels in
              let bucket_key = metric_key (name ^ "_bucket") bucket_labels in
              if value <= bound
              then
                match Hashtbl.find_opt metrics bucket_key with
                | Some m -> m.value <- m.value +. 1.0
                | None ->
                  Hashtbl.add
                    metrics
                    bucket_key
                    { name = name ^ "_bucket"
                    ; help = name ^ " bucket"
                    ; metric_type = Counter
                    ; value = 1.0
                    ; labels = bucket_labels
                    })
           bounds;
         let inf_labels = ("le", "+Inf") :: labels in
         let inf_key = metric_key (name ^ "_bucket") inf_labels in
         (match Hashtbl.find_opt metrics inf_key with
          | Some m -> m.value <- m.value +. 1.0
          | None ->
            Hashtbl.add
              metrics
              inf_key
              { name = name ^ "_bucket"
              ; help = name ^ " bucket"
              ; metric_type = Counter
              ; value = 1.0
              ; labels = inf_labels
              })
       | None -> ())))
;;
