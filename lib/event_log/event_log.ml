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

(* Bounded in-memory ring. Newest events are at the head, so [recent]
   can return a prefix without a full sort. *)
let max_events = 10_000
let events : event list ref = ref []
let mutex = Eio.Mutex.create ()

let rng = Random.State.make_self_init ()
let rng_mutex = Eio.Mutex.create ()

let generate_id () =
  let ts = Int64.of_float (Time_compat.now () *. 1000.0) in
  let uuid = Eio.Mutex.use_ro rng_mutex (fun () -> Uuidm.v4_gen rng ()) in
  Printf.sprintf "%013Ld_%s" ts (Uuidm.to_string uuid)
;;

let rec drop_last = function
  | [] -> []
  | [ _ ] -> []
  | x :: xs -> x :: drop_last xs
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
    events := event :: !events;
    if List.length !events > max_events then events := drop_last !events);
  event.id
;;

let rec take n = function
  | _ when n <= 0 -> []
  | [] -> []
  | x :: xs -> x :: take (n - 1) xs
;;

let recent ?since_id n =
  let n = max 0 n in
  Eio.Mutex.use_ro mutex (fun () ->
    match since_id with
    | None -> take n !events
    | Some since_id ->
      let drop = ref true in
      let after, _count =
        List.fold_left
          (fun (acc, remaining) e ->
             if remaining <= 0 then acc, 0
             else if !drop
             then (
               if String.equal e.id since_id then drop := false;
               acc, remaining)
             else e :: acc, remaining - 1)
          ([], n)
          !events
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
    Eio.Mutex.use_rw ~protect:true mutex (fun () -> events := [])
  ;;
end
