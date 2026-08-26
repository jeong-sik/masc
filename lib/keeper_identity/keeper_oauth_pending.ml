(** See keeper_oauth_pending.mli for why this is in memory and why nothing
    sweeps it. *)

type in_flight = {
  pending : Keeper_oauth_flow.pending;
  discovered : Keeper_oauth_discovery.t;
  client_id : string;
  client_secret : string option;
}

type entry = {
  in_flight : in_flight;
  expires_at : float;
}

(* A Stdlib mutex, not Eio's: the callback fiber and whatever started the
   login are different fibers, and this has to complete under cancellation.
   Losing the table's shape because a login was cut would be worse than the
   cut itself. *)
type t = {
  mutex : Mutex.t;
  mutable entries : (string * entry) list;
}

let create () = { mutex = Mutex.create (); entries = [] }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let live ~now entries =
  List.filter (fun (_, entry) -> entry.expires_at > now) entries

let remember t ~now ~ttl_sec in_flight =
  with_lock t (fun () ->
    let state = in_flight.pending.Keeper_oauth_flow.state in
    (* Dropping what has expired here as well keeps a table that is only ever
       written to from growing without bound. *)
    t.entries <-
      (state, { in_flight; expires_at = now +. ttl_sec })
      :: live ~now (List.remove_assoc state t.entries))

let take t ~now ~state =
  with_lock t (fun () ->
    let remaining = live ~now t.entries in
    let found = List.assoc_opt state remaining in
    t.entries <- List.remove_assoc state remaining;
    Option.map (fun entry -> entry.in_flight) found)

let waiting t ~now =
  with_lock t (fun () -> List.length (live ~now t.entries))
