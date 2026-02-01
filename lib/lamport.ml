(** Lamport Clock - Logical timestamps for causal ordering

    Based on Lamport (1978) "Time, Clocks, and the Ordering of Events
    in a Distributed System".

    In multi-agent coordination, physical time is unreliable for ordering.
    Lamport clocks provide "happened-before" causal ordering:
    - If event A caused event B, then clock(A) < clock(B)
    - If clock(A) < clock(B), we cannot conclude A caused B (partial order)

    Implementation uses OCaml 5 Atomic for lock-free thread safety.
*)

type t = {
  counter: int Atomic.t;
}

(** Create a new Lamport clock starting at 0 *)
let create () =
  { counter = Atomic.make 0 }

(** Tick: increment clock for local events
    Returns the new timestamp (atomic fetch-and-add) *)
let tick t =
  Atomic.fetch_and_add t.counter 1 + 1

(** Receive: update clock based on remote timestamp
    Lamport rule: clock = max(local, remote) + 1
    Returns the new timestamp *)
let recv t ~remote_time =
  let rec update () =
    let current = Atomic.get t.counter in
    let new_val = max current remote_time + 1 in
    if Atomic.compare_and_set t.counter current new_val then
      new_val
    else
      update ()  (* CAS retry on contention *)
  in
  update ()

(** Get current clock value without advancing *)
let current t =
  Atomic.get t.counter

(** Reset clock to 0 (for testing) *)
let reset t =
  Atomic.set t.counter 0

(** Compare two timestamps for causal ordering *)
let compare_timestamps a b =
  Int.compare a b

(** Check if timestamp a happened-before b *)
let happened_before a b =
  a < b
