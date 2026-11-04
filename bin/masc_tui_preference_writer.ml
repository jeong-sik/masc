(* The terminal's [tui] picks go to the server one at a time, in the order the
   reader made them (RFC-0482 §3.1). Two quick picks of the same key would
   otherwise race, and the one that lands last is the one stored: the screen
   would show the second pick and a restart would bring back the first. *)

type saved =
  | Committed of { durability : Runtime.config_durability; ignored_legacy_keys : string list }
  | Unchanged

type failure =
  | Not_permitted of string
  | Refused of string
  | Unobserved of string
  | Not_started of string

type request = { token : unit ref; change : Masc.Tui_preference.change }
type completion = { request : request; outcome : (saved, failure) result }
type phase = Open | Closing | Closed

type t = {
  send : Masc.Tui_preference.change -> (saved, failure) result;
  pending : request Queue.t;
  completed : completion Queue.t;
  mutable phase : phase;
  mutable idle : unit Eio.Promise.t option;
}

let create ~send =
  { send; pending = Queue.create (); completed = Queue.create (); phase = Open; idle = None }

let same_request a b = a.token == b.token
let publish t request outcome = Queue.add { request; outcome } t.completed

let refuse_pending t detail =
  Queue.iter (fun request -> publish t request (Error (Not_started detail))) t.pending;
  Queue.clear t.pending

let rec run t =
  match Queue.take_opt t.pending with
  | None -> ()
  | Some request ->
    let outcome =
      try t.send request.change with
      | Eio.Cancel.Cancelled _ as exn ->
        let bt = Printexc.get_raw_backtrace () in
        publish t request (Error (Unobserved "Save interrupted; whether the server stored it is unknown"));
        refuse_pending t "Preference writer cancelled before this pick was sent";
        Printexc.raise_with_backtrace exn bt
      | exn -> Error (Unobserved (Printexc.to_string exn))
    in
    publish t request outcome;
    run t

let start t sw =
  let idle, resolve = Eio.Promise.create () in
  t.idle <- Some idle;
  let finish () =
    t.idle <- None;
    ignore (Eio.Promise.try_resolve resolve ())
  in
  try
    (* fork can return without invoking its callback on an already cancelled
       switch. Check so close never inherits an unresolved idle promise. *)
    Eio.Switch.check sw;
    Eio.Fiber.fork ~sw (fun () -> Fun.protect ~finally:finish (fun () -> run t))
  with
  | Eio.Cancel.Cancelled _ as exn ->
    let bt = Printexc.get_raw_backtrace () in
    refuse_pending t "Preference writer cancelled before launch";
    finish ();
    Printexc.raise_with_backtrace exn bt
  | exn ->
    refuse_pending t ("Preference writer could not start: " ^ Printexc.to_string exn);
    finish ()

let submit t ~sw change =
  let request = { token = ref (); change } in
  (match t.phase, sw with
   | (Closing | Closed), _ -> publish t request (Error (Not_started "Preference writer is closing"))
   | Open, None -> publish t request (Error (Not_started "Asynchronous preference writer unavailable"))
   | Open, Some sw ->
     Queue.add request t.pending;
     if Option.is_none t.idle then start t sw);
  request

let drain_completed t ~can_take ~apply =
  let rec take remaining =
    if remaining = 0 || not (can_take ()) then ()
    else
      match Queue.take_opt t.completed with
      | None -> ()
      | Some completion ->
        apply completion;
        take (remaining - 1)
  in
  take (Queue.length t.completed)

let close t =
  t.phase <- Closing;
  (* Graceful drain, not a shutdown deadline: a pick already sent keeps this
     wait until its answer, so cancellation never turns a write still in
     flight into an unknown receipt. *)
  Eio.Cancel.protect (fun () -> Option.iter Eio.Promise.await t.idle);
  t.phase <- Closed
