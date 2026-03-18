(** Perpetual_oas_state — Mutable state for OAS perpetual agent hook closures.

    Extracted from [perpetual_oas.ml] to isolate the mutable state type,
    constructor, and mutex-protected access helpers.

    The OAS hook API requires mutable state captured by closures —
    immutable state is not an option here.

    @since 2.111.0 — H2 God File split *)

(** Mutable state carried through hook closures across turns.
    Mirrors the subset of [Perpetual_loop.loop_state] that hooks need
    for threshold checking, idle detection, and metrics accumulation. *)
type perpetual_state = {
  mutable turn_count : int;
  mutable idle_turns : int;
  mutable total_tokens : int;
  mutable total_cost : float;
  mutable last_heartbeat : float;
  mutable compaction_count : int;
  mutable generation : int;
  mutable running : bool;
  mutable handoff_triggered : bool;
  trace_id : string;
}

let create_perpetual_state ~trace_id =
  {
    turn_count = 0;
    idle_turns = 0;
    total_tokens = 0;
    total_cost = 0.0;
    last_heartbeat = Time_compat.now ();
    compaction_count = 0;
    generation = 0;
    running = true;
    handoff_triggered = false;
    trace_id;
  }

(** Mutex protecting all mutable [perpetual_state] fields from concurrent
    access by Eio fibers (hook closures, periodic callbacks). *)
let state_mutex = Eio.Mutex.create ()

(** Read from state under mutex protection. *)
let with_state (f : perpetual_state -> 'a) (pstate : perpetual_state) : 'a =
  Eio.Mutex.use_rw ~protect:true state_mutex (fun () -> f pstate)

(** Write to state under mutex protection. *)
let update_state (f : perpetual_state -> unit) (pstate : perpetual_state) : unit =
  Eio.Mutex.use_rw ~protect:true state_mutex (fun () -> f pstate)
