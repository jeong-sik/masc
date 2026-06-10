(** Incremental telemetry summary for fleet health.

    Maintains in-memory incremental counters aggregated from telemetry
    events as they arrive on the OAS event bus.  Avoids O(N) re-scan of
    durable telemetry data — counters are updated on each
    {!record_event} call.

    Thread safety: uses {!Stdlib.Mutex} (not Eio.Mutex) for cross-fiber
    safety without Eio dependency in the health tracker
    (per feedback_ocaml5-mutex-selection.md). *)

type telemetry_entry = {
  timestamp : float;
  keeper_name : string;
  event_kind : string;
  runtime_id : string option;
  duration_ms : float option;
  success : bool;
}

type fleet_snapshot = {
  total_events : int;
  successful_events : int;
  failed_events : int;
  per_keeper : (string, keeper_counters) Hashtbl.t;
  recent_events : telemetry_entry list;
}

and keeper_counters = {
  total : int;
  success : int;
  failure : int;
  avg_duration_ms : float;
}

(* ── Internal state ────────────────────────────────────────────── *)

let mu = Stdlib.Mutex.create ()

(* Global counters, protected by [mu]. *)
let total_events = ref 0
let successful_events = ref 0
let failed_events = ref 0

(* Per-keeper counters, protected by [mu].
   Map keys are keeper names. Each entry is {total; success; failure; duration_sum_ms}. *)
let per_keeper : (string, int * int * int * float) Hashtbl.t = Hashtbl.create 16

(* Ring buffer of recent events, protected by [mu].
   LIFO — most recent first. Trimmed to [max_recent_events] on insert. *)
let max_recent_events = 100
let recent_events : telemetry_entry list ref = ref []

(* ── Helpers ───────────────────────────────────────────────────── *)

let with_lock f =
  Stdlib.Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock mu) f

(* ── Public API ────────────────────────────────────────────────── *)

let record_event ~keeper_name ~event_kind ~runtime_id ~duration_ms ~success =
  let entry = {
    timestamp = Unix.gettimeofday ();
    keeper_name;
    event_kind;
    runtime_id;
    duration_ms;
    success;
  } in
  with_lock (fun () ->
    (* Update global counters *)
    incr total_events;
    if success then incr successful_events else incr failed_events;

    (* Update per-keeper counters *)
    let t, s, f, d =
      match Hashtbl.find_opt per_keeper keeper_name with
      | Some v -> v
      | None -> (0, 0, 0, 0.0)
    in
    let d' =
      match duration_ms with
      | Some ms -> d +. ms
      | None -> d
    in
    Hashtbl.replace per_keeper keeper_name ((t + 1), (if success then s + 1 else s), (if success then f else f + 1), d');

    (* Append to recent events ring buffer *)
    recent_events := entry :: !recent_events;
    if List.length !recent_events > max_recent_events then
      recent_events := List.take max_recent_events !recent_events
  )

let snapshot () =
  with_lock (fun () ->
    let per_keeper_snapshot = Hashtbl.create (Hashtbl.length per_keeper) in
    Hashtbl.iter (fun name (t, s, f, d) ->
      let avg_duration_ms =
        if t > 0 then d /. Float.of_int t else 0.0
      in
      Hashtbl.replace per_keeper_snapshot name
        { total = t; success = s; failure = f; avg_duration_ms }
    ) per_keeper;
    {
      total_events = !total_events;
      successful_events = !successful_events;
      failed_events = !failed_events;
      per_keeper = per_keeper_snapshot;
      recent_events = List.rev !recent_events;
    }
  )

let reset () =
  with_lock (fun () ->
    total_events := 0;
    successful_events := 0;
    failed_events := 0;
    Hashtbl.clear per_keeper;
    recent_events := []
  )

let reset_keeper ~keeper_name =
  with_lock (fun () ->
    Hashtbl.remove per_keeper keeper_name
  )