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

(* Every series, by its key and by its name. The tables are reachable only
   through this signature, so a series cannot enter one without the other: a
   total over one name reads that name's series and sees all of them. Both
   tables hold the same mutable records, so a total reads values as they are
   updated, and nothing removes a series. Every operation runs with
   [metrics_mutex] held. *)
module Series : sig
  val mem : string -> bool
  val find_opt : string -> metric option
  val add : string -> metric -> unit
  val fold : (metric -> 'acc -> 'acc) -> 'acc -> 'acc
  val total : string -> float
end = struct
  let by_key : (string, metric) Hashtbl.t = Hashtbl.create 64
  let by_name : (string, metric list) Hashtbl.t = Hashtbl.create 64
  let mem key = Hashtbl.mem by_key key
  let find_opt key = Hashtbl.find_opt by_key key

  let add key (series : metric) =
    let named =
      match Hashtbl.find_opt by_name series.name with
      | Some named -> named
      | None -> []
    in
    Hashtbl.add by_key key series;
    Hashtbl.replace by_name series.name (series :: named)
  ;;

  let fold f init = Hashtbl.fold (fun _ series acc -> f series acc) by_key init

  let total name =
    match Hashtbl.find_opt by_name name with
    | Some named -> List.fold_left (fun acc (m : metric) -> acc +. m.value) 0.0 named
    | None -> 0.0
  ;;
end

(** Metrics are shared by fibers/domains, so reads and writes are serialized
    through [Stdlib.Mutex]. It is available during module initialization and
    protects both registration and float updates. *)
let metrics_mutex = Stdlib.Mutex.create ()
;;

(* #10682: capture the caller stack for rare EDEADLK re-entry failures so the
   next diagnostic render can name the offending metric path. *)
let last_deadlock_backtrace : string option Atomic.t = Atomic.make None

let with_lock f =
  (try Stdlib.Mutex.lock metrics_mutex with
   | Sys_error msg as exn ->
     let trace = Printexc.raw_backtrace_to_string (Printexc.get_callstack 64) in
     let dump = Printf.sprintf "Otel_metric_store.with_lock: %s\nCaller stack:\n%s" msg trace in
     Atomic.set last_deadlock_backtrace (Some dump);
     Log.Metrics.error "Otel_metric_store mutex deadlock: %s" dump;
     raise exn);
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock metrics_mutex) f
;;

(** Best-effort wrapper: never crash the caller fiber for a metrics update.
    Metrics are advisory; losing one sample must not take down the OTel tick
    fiber or the keeper turn.

    [Cancel_safe.observe] (RFC-0106) draws the one line this wrapper must not
    cross: [Eio.Cancel.Cancelled] leaves verbatim, every other exception becomes
    a warning. Until #37349 the handler was a bare [| exn ->], so a counter
    bumped inside a cancelled fiber would have turned the cancellation into a
    log line and let the caller run on.

    Nothing under this wrapper suspends today — [metric_key] is string work and
    [with_lock] is [Stdlib.Mutex] plus [Hashtbl] — so [Cancelled] has no way to
    originate here and no call site changes behaviour.

    The guard covers what runs under [best_effort] but outside [with_lock].
    Work moved under the lock sits behind [Fun.protect ~finally:unlock]: a body
    that raises [Cancelled] together with an unlock that then raises (the
    [Sys_error] path above) loses the [Cancelled] to [Fun.Finally_raised],
    which this wrapper treats as an ordinary failure. No re-raise here can
    recover what [Fun.protect] already dropped, so putting a suspending call
    under the lock needs [with_lock] settled first. *)
let best_effort f =
  Cancel_safe.observe
    ~on_exn:(fun exn ->
      Log.Metrics.warn
        "Otel_metric_store update failed (non-fatal): %s"
        (Printexc.to_string exn))
    f
;;

let register_counter ~name ~help ?(labels = []) () =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      if not (Series.mem key)
      then
        Series.add key { name; help; metric_type = Counter; value = 0.0; labels }))
;;

(* Zero-fill declaration: registers the unlabeled 0-cell at module-init time
   and hands the name back so `let metric_x = declare_counter "..."` keeps
   the constant shape. *)
let declare_counter name =
  register_counter ~name ~help:name ();
  name
;;

let register_gauge ~name ~help ?(labels = []) () =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      if not (Series.mem key)
      then Series.add key { name; help; metric_type = Gauge; value = 0.0; labels }))
;;

let register_histogram ~name ~help ?(labels = []) () =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      if not (Series.mem key)
      then
        Series.add key { name; help; metric_type = Histogram; value = 0.0; labels }))
;;

let declare_gauge name =
  register_gauge ~name ~help:name ();
  name
;;

let histogram_count_name name = name ^ "_count"

let declare_histogram name =
  register_histogram ~name ~help:name ();
  register_counter
    ~name:(histogram_count_name name)
    ~help:(name ^ " observation count")
    ();
  name
;;

let histogram_buckets : (string, float list) Hashtbl.t = Hashtbl.create 16

let register_histogram_buckets name bounds =
  best_effort (fun () ->
    with_lock (fun () -> Hashtbl.replace histogram_buckets name bounds))
;;

let histogram_bound_label bound =
  let label = Float.to_string bound in
  let last = String.length label - 1 in
  if last >= 0 && Char.equal label.[last] '.'
  then String.sub label 0 last
  else label
;;

let inc_counter name ?(labels = []) ?(delta = 1.0) () =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      match Series.find_opt key with
      | Some m -> m.value <- m.value +. delta
      | None ->
        Series.add
          key
          { name; help = name; metric_type = Counter; value = delta; labels }))
;;

let set_gauge name ?(labels = []) value =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      match Series.find_opt key with
      | Some m -> m.value <- value
      | None ->
        Series.add key { name; help = name; metric_type = Gauge; value; labels }))
;;

let inc_gauge name ?(labels = []) ?(delta = 1.0) () =
  best_effort (fun () ->
    let key = metric_key name labels in
    with_lock (fun () ->
      match Series.find_opt key with
      | Some m -> m.value <- m.value +. delta
      | None ->
        Series.add
          key
          { name; help = name; metric_type = Gauge; value = delta; labels }))
;;

let dec_gauge name ?(labels = []) ?(delta = 1.0) () =
  inc_gauge name ~labels ~delta:(-.delta) ()
;;

let get_metric_value name ?(labels = []) () =
  let key = metric_key name labels in
  with_lock (fun () -> Series.find_opt key |> Option.map (fun m -> m.value))
;;

let metric_value_or_zero name ?(labels = []) () =
  get_metric_value name ~labels () |> Option.value ~default:0.0
;;

let metric_total name = with_lock (fun () -> Series.total name)

let snapshot () =
  with_lock (fun () ->
    Series.fold
      (fun (m : metric) acc ->
         { name = m.name
         ; help = m.help
         ; metric_type = m.metric_type
         ; value = m.value
         ; labels = m.labels
         }
         :: acc)
      [])
;;

let observe_histogram name ?(labels = []) value =
  best_effort (fun () ->
    let key = metric_key name labels in
    let count_name = histogram_count_name name in
    let count_key = metric_key count_name labels in
    with_lock (fun () ->
      (match Series.find_opt key with
       | Some m -> m.value <- m.value +. value
       | None ->
         Series.add
           key
           { name; help = name; metric_type = Histogram; value; labels });
      (match Series.find_opt count_key with
       | Some m -> m.value <- m.value +. 1.0
       | None ->
         Series.add
           count_key
           { name = count_name
           ; help = name ^ " observation count"
           ; metric_type = Counter
           ; value = 1.0
           ; labels
           });
      (match Hashtbl.find_opt histogram_buckets name with
       | Some bounds ->
         List.iter
           (fun bound ->
              let le = histogram_bound_label bound in
              let bucket_labels = ("le", le) :: labels in
              let bucket_key = metric_key (name ^ "_bucket") bucket_labels in
              if value <= bound
              then
                match Series.find_opt bucket_key with
                | Some m -> m.value <- m.value +. 1.0
                | None ->
                  Series.add
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
         (match Series.find_opt inf_key with
          | Some m -> m.value <- m.value +. 1.0
          | None ->
            Series.add
              inf_key
              { name = name ^ "_bucket"
              ; help = name ^ " bucket"
              ; metric_type = Counter
              ; value = 1.0
              ; labels = inf_labels
              })
       | None -> ())))
;;
