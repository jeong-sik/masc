type request = {
  token : unit ref;
  base_path : string;
  keeper : Keeper_id.Keeper_name.t;
}
type outcome =
  | Saved of Runtime.config_durability
  | Refused of string
  | Unobserved of string
  | Not_started of string
type completion = { request : request; outcome : outcome }
type phase = Open | Closing | Closed
type t = {
  pending : request Queue.t;
  completed : completion Queue.t;
  mutable phase : phase;
  mutable idle : unit Eio.Promise.t option;
}

let create () = { pending = Queue.create (); completed = Queue.create (); phase = Open; idle = None }
let same_request a b = a.token == b.token
let publish t request outcome = Queue.add { request; outcome } t.completed
let refuse_pending t detail =
  Queue.iter (fun request -> publish t request (Not_started detail)) t.pending;
  Queue.clear t.pending

let rec run t =
  match Queue.take_opt t.pending with
  | None -> ()
  | Some request ->
      let outcome =
        try
          match Domain_pool_ref.submit_io_or_inline (fun () ->
            Masc_tui_config.record_chat_visit ~base_path:request.base_path request.keeper) with
          | Ok durability -> Saved durability
          | Error detail -> Refused detail
        with
        | Eio.Cancel.Cancelled _ as exn ->
            let bt = Printexc.get_raw_backtrace () in
            publish t request (Unobserved "Conversation save interrupted; commit outcome not observed");
            refuse_pending t "Conversation writer cancelled before this visit started";
            Printexc.raise_with_backtrace exn bt
        | exn -> Unobserved (Printexc.to_string exn)
      in
      publish t request outcome;
      run t

let start t sw =
  let idle, resolve = Eio.Promise.create () in
  t.idle <- Some idle;
  let finish () = t.idle <- None; ignore (Eio.Promise.try_resolve resolve ()) in
  try
    (* fork can return without invoking its callback on an already cancelled
       switch. Check so close never inherits an unresolved idle promise. *)
    Eio.Switch.check sw;
    Eio.Fiber.fork ~sw (fun () -> Fun.protect ~finally:finish (fun () -> run t))
  with
  | Eio.Cancel.Cancelled _ as exn ->
      let bt = Printexc.get_raw_backtrace () in
      refuse_pending t "Conversation writer cancelled before launch";
      finish ();
      Printexc.raise_with_backtrace exn bt
  | exn ->
      refuse_pending t ("Conversation writer could not start: " ^ Printexc.to_string exn);
      finish ()

let submit t ~sw ~base_path keeper =
  let request = { token = ref (); base_path; keeper } in
  (match t.phase, sw with
   | (Closing | Closed), _ -> publish t request (Not_started "Conversation writer is closing")
   | Open, None -> publish t request (Not_started "Asynchronous conversation writer unavailable")
   | Open, Some sw ->
       Queue.add request t.pending;
       if Option.is_none t.idle then start t sw);
  request

let drain_completed t ~can_take ~apply =
  let rec take remaining =
    if remaining = 0 || not (can_take ()) then ()
    else match Queue.take_opt t.completed with
      | None -> ()
      | Some completion -> apply completion; take (remaining - 1)
  in
  take (Queue.length t.completed)

let close t =
  t.phase <- Closing;
  (* Graceful drain, not a shutdown deadline. A config operation that never
     settles keeps this wait in Closing; caller cancellation does not turn a
     still-running effect into an unknown/finished receipt. *)
  Eio.Cancel.protect (fun () -> Option.iter Eio.Promise.await t.idle);
  t.phase <- Closed
