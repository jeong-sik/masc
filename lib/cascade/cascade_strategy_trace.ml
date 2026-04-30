(** See cascade_strategy_trace.mli for documentation. *)

type event_kind = Ordered | Filtered_empty | Exhausted

type event = {
  ts : float;
  cascade_name : Keeper_cascade_profile.runtime_name;
  strategy : string;
  cycle : int;
  candidates_in : int;
  candidates_out : int;
  backoff_ms : int;
  kind : event_kind;
  trace_id : string option;
}

let kind_to_string = function
  | Ordered -> "ordered"
  | Filtered_empty -> "filtered_empty"
  | Exhausted -> "exhausted"

let default_capacity = 1024
let min_capacity = 16
let max_capacity = 65536

let resolve_capacity () =
  let from_env =
    match Sys.getenv_opt "MASC_STRATEGY_TRACE_SIZE" with
    | None | Some "" -> default_capacity
    | Some s ->
      (match int_of_string_opt (String.trim s) with
       | Some n -> n
       | None -> default_capacity)
  in
  max min_capacity (min max_capacity from_env)

(* Ring buffer: same invariants as Cascade_client_capacity_history. *)

let cap_ref = ref 0
let buf : event option array ref = ref [||]
let head = ref 0
let count = ref 0
let mu = Mutex.create ()

let ensure_initialised_locked () =
  if !cap_ref = 0 then begin
    let cap = resolve_capacity () in
    cap_ref := cap;
    buf := Array.make cap None;
    head := 0;
    count := 0
  end

(* Prometheus counter increment happens *outside* the ring mutex so a slow
   metrics hashtable mutex cannot block cascade strategy paths.  Labels
   mirror the JSON projection ({cascade, strategy, kind}) so Grafana can
   join on the same tuple surfaced to the dashboard card. *)
let bump_prometheus_counter (ev : event) =
  Prometheus.inc_counter Prometheus.metric_cascade_strategy_decisions
    ~labels:[
      "cascade", Keeper_cascade_profile.runtime_name_to_string ev.cascade_name;
      "strategy", ev.strategy;
      "kind", kind_to_string ev.kind;
    ] ()

let record ev =
  Mutex.protect mu (fun () ->
      ensure_initialised_locked ();
      let cap = !cap_ref in
      (!buf).(!head) <- Some ev;
      head := (!head + 1) mod cap;
      if !count < cap then incr count);
  bump_prometheus_counter ev

let clear () =
  Mutex.protect mu (fun () ->
      ensure_initialised_locked ();
      let cap = !cap_ref in
      for i = 0 to cap - 1 do (!buf).(i) <- None done;
      head := 0;
      count := 0)

let size () = Mutex.protect mu (fun () -> !count)

let capacity () =
  Mutex.protect mu (fun () ->
      ensure_initialised_locked ();
      !cap_ref)

let collect_newest_first_locked () =
  let cap = !cap_ref in
  let n = !count in
  let acc = ref [] in
  for i = n - 1 downto 0 do
    let idx = (!head - 1 - i + cap) mod cap in
    match (!buf).(idx) with
    | Some e -> acc := e :: !acc
    | None -> ()
  done;
  !acc

let snapshot ?(limit = 100) ?cascade () =
  let events =
    Mutex.protect mu (fun () ->
        ensure_initialised_locked ();
        collect_newest_first_locked ())
  in
  let cascade_match =
    match cascade with
    | None -> fun _ -> true
    | Some c ->
        fun (e : event) ->
          String.equal
            (Keeper_cascade_profile.runtime_name_to_string e.cascade_name)
            c
  in
  let limit = max 0 limit in
  let rec take n xs =
    if n <= 0 then []
    else
      match xs with
      | [] -> []
      | x :: tl -> x :: take (n - 1) tl
  in
  events |> List.filter cascade_match |> take limit
