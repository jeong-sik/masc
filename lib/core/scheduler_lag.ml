(* See scheduler_lag.mli for what the probe measures and why the ring is
   atomic per slot. *)

type t =
  { interval_s : float
  ; slots : float Atomic.t array
  ; (* Samples recorded so far. The slot for sample [n] is [n mod window]. The
       writer stores the slot before advancing the cursor, so a reader that
       trusts the cursor never reads a slot the writer has not filled yet. *)
    cursor : int Atomic.t
  ; started : bool Atomic.t
  ; failure : string option Atomic.t
  }

let default_interval_s = 0.1
let default_window = 600
let stall_threshold_s = 1.0

let create ?(interval_s = default_interval_s) ?(window = default_window) () =
  if interval_s <= 0.0
  then invalid_arg "Scheduler_lag.create: interval_s must be positive";
  if window <= 0 then invalid_arg "Scheduler_lag.create: window must be positive";
  { interval_s
  ; slots = Array.init window (fun _ -> Atomic.make 0.0)
  ; cursor = Atomic.make 0
  ; started = Atomic.make false
  ; failure = Atomic.make None
  }
;;

let global = create ()

let record t ~lag_s =
  let n = Atomic.get t.cursor in
  Atomic.set t.slots.(n mod Array.length t.slots) lag_s;
  Atomic.incr t.cursor
;;

let samples t =
  let recorded = Atomic.get t.cursor in
  let count = Int.min recorded (Array.length t.slots) in
  Array.init count (fun i -> Atomic.get t.slots.(i))
;;

type summary =
  { samples : int
  ; p50_ms : float
  ; p95_ms : float
  ; p99_ms : float
  ; max_ms : float
  ; mean_ms : float
  ; stalls : int
  }

(* Nearest-rank percentile: the smallest value such that [p] of the samples
   are at or below it. [sorted] is ascending and non-empty. *)
let nearest_rank sorted p =
  let n = Array.length sorted in
  let rank = int_of_float (Float.ceil (p *. Float.of_int n)) in
  sorted.(Int.max 0 (Int.min (n - 1) (rank - 1)))
;;

let milliseconds_per_second = 1000.0
let nanoseconds_per_second = 1e9

let summarize t =
  let xs = samples t in
  let n = Array.length xs in
  if n = 0
  then None
  else begin
    Array.sort Float.compare xs;
    let ms seconds = seconds *. milliseconds_per_second in
    let sum = Array.fold_left ( +. ) 0.0 xs in
    let stalls =
      Array.fold_left
        (fun acc x -> if x >= stall_threshold_s then acc + 1 else acc)
        0
        xs
    in
    Some
      { samples = n
      ; p50_ms = ms (nearest_rank xs 0.50)
      ; p95_ms = ms (nearest_rank xs 0.95)
      ; p99_ms = ms (nearest_rank xs 0.99)
      ; max_ms = ms xs.(n - 1)
      ; mean_ms = ms (sum /. Float.of_int n)
      ; stalls
      }
  end
;;

let to_fields t : (string * Yojson.Safe.t) list =
  let probe =
    match Atomic.get t.failure with
    | Some reason ->
      [ "probe", `String "stopped"; "stopped_reason", `String reason ]
    | None ->
      if Atomic.get t.started
      then [ "probe", `String "running" ]
      else [ "probe", `String "not_started" ]
  in
  let shape =
    [ "interval_ms", `Float (t.interval_s *. milliseconds_per_second)
    ; "window_s", `Float (t.interval_s *. Float.of_int (Array.length t.slots))
    ; "stall_threshold_ms", `Float (stall_threshold_s *. milliseconds_per_second)
    ]
  in
  let stats =
    match summarize t with
    | None -> [ "samples", `Int 0 ]
    | Some s ->
      [ "samples", `Int s.samples
      ; "p50_ms", `Float s.p50_ms
      ; "p95_ms", `Float s.p95_ms
      ; "p99_ms", `Float s.p99_ms
      ; "max_ms", `Float s.max_ms
      ; "mean_ms", `Float s.mean_ms
      ; "stalls", `Int s.stalls
      ]
  in
  probe @ shape @ stats
;;

let to_yojson t : Yojson.Safe.t = `Assoc (to_fields t)

let start ~sw ~(mono_clock : _ Eio.Time.Mono.t) t =
  if Atomic.compare_and_set t.started false true
  then
    Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        let before = Eio.Time.Mono.now mono_clock in
        Eio.Time.Mono.sleep mono_clock t.interval_s;
        let after = Eio.Time.Mono.now mono_clock in
        let elapsed_s =
          Mtime.Span.to_float_ns (Mtime.span before after) /. nanoseconds_per_second
        in
        record t ~lag_s:(Float.max 0.0 (elapsed_s -. t.interval_s));
        loop ()
      in
      try loop () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Atomic.set t.failure (Some (Printexc.to_string exn)))
;;
