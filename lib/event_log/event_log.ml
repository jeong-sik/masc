(** Event_log — single canonical event stream for MASC.

    P2-2 foundation: a time-ordered, uniquely identified in-memory event
    log that REST, SSE, and the keeper event bus can all publish into.
    JSONL persistence and subscriber fan-out are deliberate follow-ups. *)

type source = string

type event_id = string

type event =
  { id : event_id
  ; ts_unix : float
  ; source : source
  ; kind : string
  ; payload : Yojson.Safe.t
  }

(* Bounded in-memory ring buffer. Events are written into a fixed-size
   array and overwritten in place, so [publish] is O(1) with no per-event
   list scan or rebuild. The newest event is logically first, so [recent]
   returns a newest-first prefix.

   Invariant: the [count] slots at indices [(oldest + k) mod max_events]
   for [k] in [0, count) hold published events in oldest-to-newest order.
   Every other slot holds [empty_event] and is never read. *)
let max_events = 10_000

(* Fill value for unwritten slots. Never observable: reads touch only the
   [count] valid slots tracked by [oldest] and [count]. *)
let empty_event =
  { id = ""; ts_unix = 0.0; source = ""; kind = ""; payload = `Null }

let ring = Array.make max_events empty_event
let oldest = ref 0
let count = ref 0
let mutex = Eio.Mutex.create ()

let rng = Random.State.make_self_init ()
let rng_mutex = Eio.Mutex.create ()

let generate_id () =
  let ts = Int64.of_float (Time_compat.now () *. 1000.0) in
  let uuid = Eio.Mutex.use_ro rng_mutex (fun () -> Uuidm.v4_gen rng ()) in
  Printf.sprintf "%013Ld_%s" ts (Uuidm.to_string uuid)
;;

let publish ~source ~kind payload =
  let event =
    { id = generate_id ()
    ; ts_unix = Time_compat.now ()
    ; source
    ; kind
    ; payload
    }
  in
  Eio.Mutex.use_rw ~protect:true mutex (fun () ->
    let write_pos = (!oldest + !count) mod max_events in
    ring.(write_pos) <- event;
    if !count < max_events then incr count
    else oldest := (!oldest + 1) mod max_events);
  event.id
;;

(* Snapshot the log newest-first, reproducing the historical [event list]
   representation exactly so the read logic below stays unchanged. Caller
   must hold [mutex]. *)
let snapshot_newest_first () =
  let n = !count in
  let rec build k acc =
    if k >= n then acc
    else (
      let idx = (!oldest + k) mod max_events in
      build (k + 1) (ring.(idx) :: acc))
  in
  build 0 []
;;

let rec take n = function
  | _ when n <= 0 -> []
  | [] -> []
  | x :: xs -> x :: take (n - 1) xs
;;

let recent ?since_id n =
  let n = max 0 n in
  Eio.Mutex.use_ro mutex (fun () ->
    let events = snapshot_newest_first () in
    match since_id with
    | None -> take n events
    | Some since_id ->
      let drop = ref true in
      let after, _remaining =
        List.fold_left
          (fun (acc, remaining) e ->
             if remaining <= 0 then acc, 0
             else if !drop
             then (
               if String.equal e.id since_id then drop := false;
               acc, remaining)
             else e :: acc, remaining - 1)
          ([], n)
          events
      in
      List.rev after)
;;

let to_json e =
  `Assoc
    [ ("id", `String e.id)
    ; ("ts_unix", `Float e.ts_unix)
    ; ("source", `String e.source)
    ; ("kind", `String e.kind)
    ; ("payload", e.payload)
    ]
;;

module For_testing = struct
  let reset () =
    Eio.Mutex.use_rw ~protect:true mutex (fun () ->
      Array.fill ring 0 max_events empty_event;
      oldest := 0;
      count := 0)
  ;;

  let capacity = max_events
end
