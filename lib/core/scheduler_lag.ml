(* See scheduler_lag.mli for what the probe measures and why the ring is
   atomic per slot. *)

type probe_state =
  | Not_started
  | Running
  | Stopped of string
  | Cancelled

type t =
  { interval_s : float
  ; slots : float Atomic.t array
  ; (* Samples recorded so far. The slot for sample [n] is [n mod window]. The
       single writer stores the slot before advancing the cursor, so a reader
       that trusts the cursor never reads a slot the writer has not filled. *)
    cursor : int Atomic.t
  ; state : probe_state Atomic.t
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
  ; state = Atomic.make Not_started
  }
;;

let global = create ()
let record t ~lag_s =
  let n = Atomic.get t.cursor in
  Atomic.set t.slots.(n mod Array.length t.slots) lag_s;
  Atomic.incr t.cursor
;;

module For_testing = struct
  let record = record
end

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

(* Nearest rank: the index an ascending sort of [n] samples would give the
   smallest value such that [p] of the samples are at or below it. *)
let nearest_rank_index n p =
  let rank = int_of_float (Float.ceil (p *. Float.of_int n)) in
  Int.max 0 (Int.min (n - 1) (rank - 1))
;;

(* Each round of [select] partitions a slice around the value at its middle
   index and keeps the side that holds the rank. A ring whose order keeps an
   extreme value at the middle index -- a lag that falls and rises within the
   window -- sheds a sample or two per round, so a selection would cost a
   round per sample. A selection therefore gets two rounds per halving of its
   slice and sorts the slice it is left with once they are spent: at worst it
   costs those rounds and one sort. *)
let rounds_per_halving = 2

(* The fewest halvings that bring [m] samples down to one. *)
let halvings_to_one m =
  let rec count halvings =
    if 1 lsl halvings >= m then halvings else count (halvings + 1)
  in
  count 0
;;

(* [select xs lo hi k] puts at [xs.(k)] a value equal, by [Float.compare], to
   the one an ascending sort would put there, and leaves every value in
   [lo, k) at or below it and every value in (k, hi] at or above it. It
   reorders only [xs.(lo..hi)], which must contain [k]. *)
let rec select_within xs lo hi k ~rounds =
  if lo < hi
  then
    if rounds = 0
    then Array.stable_sort_sub Float.compare xs lo (hi - lo + 1)
    else begin
      let pivot = xs.(lo + ((hi - lo) / 2)) in
      let i = ref lo in
      let j = ref hi in
      while !i <= !j do
        while Float.compare xs.(!i) pivot < 0 do
          incr i
        done;
        while Float.compare xs.(!j) pivot > 0 do
          decr j
        done;
        if !i <= !j
        then begin
          let v = xs.(!i) in
          xs.(!i) <- xs.(!j);
          xs.(!j) <- v;
          incr i;
          decr j
        end
      done;
      (* Every index between [!j] and [!i] holds the pivot, already in place. *)
      let rounds = rounds - 1 in
      if k <= !j
      then select_within xs lo !j k ~rounds
      else if k >= !i
      then select_within xs !i hi k ~rounds
    end
;;

let select xs lo hi k =
  select_within xs lo hi k ~rounds:(rounds_per_halving * halvings_to_one (hi - lo + 1))
;;

let milliseconds_per_second = 1000.0
let nanoseconds_per_second = 1e9

let summarize t =
  let xs = samples t in
  let n = Array.length xs in
  if n = 0
  then None
  else begin
    let ms seconds = seconds *. milliseconds_per_second in
    let sum = Array.fold_left ( +. ) 0.0 xs in
    let stalls =
      Array.fold_left
        (fun acc x -> if x >= stall_threshold_s then acc + 1 else acc)
        0
        xs
    in
    let largest =
      Array.fold_left
        (fun acc x -> if Float.compare x acc > 0 then x else acc)
        xs.(0)
        xs
    in
    (* The three ranks ascend, and after each selection every sample above
       the chosen index is at or above the chosen value, so the next rank is
       looked for only there. Only [xs], the copy [samples] made, is
       reordered. *)
    let at_rank ~above p =
      let k = nearest_rank_index n p in
      select xs above (n - 1) k;
      k, xs.(k)
    in
    let k50, p50 = at_rank ~above:0 0.50 in
    let k95, p95 = at_rank ~above:k50 0.95 in
    let _, p99 = at_rank ~above:k95 0.99 in
    Some
      { samples = n
      ; p50_ms = ms p50
      ; p95_ms = ms p95
      ; p99_ms = ms p99
      ; max_ms = ms largest
      ; mean_ms = ms (sum /. Float.of_int n)
      ; stalls
      }
  end
;;

let to_fields t : (string * Yojson.Safe.t) list =
  let probe =
    match Atomic.get t.state with
    | Not_started -> [ "probe", `String "not_started" ]
    | Running -> [ "probe", `String "running" ]
    | Stopped reason ->
      [ "probe", `String "stopped"; "stopped_reason", `String reason ]
    | Cancelled -> [ "probe", `String "cancelled" ]
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

let start ~sw ~(mono_clock : _ Eio.Time.Mono.t) t =
  if Atomic.compare_and_set t.state Not_started Running
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
      | Eio.Cancel.Cancelled _ as exn ->
        Atomic.set t.state Cancelled;
        raise exn
      | exn -> Atomic.set t.state (Stopped (Printexc.to_string exn)))
;;
