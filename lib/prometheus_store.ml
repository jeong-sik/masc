(** Mutex-backed Prometheus metric store. *)

type label = string * string

let metric_key = Prometheus_key.metric_key

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
     let dump = Printf.sprintf "Prometheus.with_lock: %s\nCaller stack:\n%s" msg trace in
     Atomic.set last_deadlock_backtrace (Some dump);
     Printf.eprintf "[ERROR] [Prometheus] %s\n%!" dump;
     raise exn);
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock metrics_mutex) f
;;

let last_deadlock_backtrace_for_test () = Atomic.get last_deadlock_backtrace

let register_counter ~name ~help ?(labels = []) () =
  let key = metric_key name labels in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key)
    then
      Hashtbl.add metrics key { name; help; metric_type = Counter; value = 0.0; labels })
;;

let register_gauge ~name ~help ?(labels = []) () =
  let key = metric_key name labels in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key)
    then Hashtbl.add metrics key { name; help; metric_type = Gauge; value = 0.0; labels })
;;

let register_histogram ~name ~help ?(labels = []) () =
  let key = metric_key name labels in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key)
    then
      Hashtbl.add metrics key { name; help; metric_type = Histogram; value = 0.0; labels })
;;

let inc_counter name ?(labels = []) ?(delta = 1.0) () =
  let key = metric_key name labels in
  with_lock (fun () ->
    match Hashtbl.find_opt metrics key with
    | Some m -> m.value <- m.value +. delta
    | None ->
      Hashtbl.add
        metrics
        key
        { name; help = name; metric_type = Counter; value = delta; labels })
;;

let set_gauge name ?(labels = []) value =
  let key = metric_key name labels in
  with_lock (fun () ->
    match Hashtbl.find_opt metrics key with
    | Some m -> m.value <- value
    | None ->
      Hashtbl.add metrics key { name; help = name; metric_type = Gauge; value; labels })
;;

let inc_gauge name ?(labels = []) ?(delta = 1.0) () =
  let key = metric_key name labels in
  with_lock (fun () ->
    match Hashtbl.find_opt metrics key with
    | Some m -> m.value <- m.value +. delta
    | None ->
      Hashtbl.add
        metrics
        key
        { name; help = name; metric_type = Gauge; value = delta; labels })
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

let snapshot_metrics () =
  with_lock (fun () ->
    Hashtbl.fold (fun _ (m : metric) acc -> { m with value = m.value } :: acc) metrics [])
;;

let observe_histogram name ?(labels = []) value =
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
    match Hashtbl.find_opt metrics count_key with
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
        })
;;
