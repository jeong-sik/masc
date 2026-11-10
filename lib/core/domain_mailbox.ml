(* [gate] orders a [send] against the end of [serve]: a send sees [ended]
   and queues under it, and the end sets [ended] and empties the queue under
   it, so no operation is queued after the queue was emptied. Under it are a
   flag and queue operations that do not wait: [Eio.Stream.add] waits only on
   a full stream, and this one has no bound. *)
type 'op t =
  { ops : 'op Eio.Stream.t
  ; gate : Stdlib.Mutex.t
  ; mutable ended : bool
  }

let create () =
  { ops = Eio.Stream.create max_int; gate = Stdlib.Mutex.create (); ended = false }
;;

let send t op =
  Stdlib.Mutex.protect t.gate (fun () ->
    if t.ended
    then false
    else (
      Eio.Stream.add t.ops op;
      true))
;;

let end_and_drain t =
  Stdlib.Mutex.protect t.gate (fun () ->
    t.ended <- true;
    let rec drain rev_ops =
      match Eio.Stream.take_nonblocking t.ops with
      | Some op -> drain (op :: rev_ops)
      | None -> List.rev rev_ops
    in
    drain [])
;;

let serve t ~handle ~unhandled =
  (* The operation [handle] is working on is in no queue, so a raise there
     would lose it: [in_hand] keeps it until [handle] has answered. *)
  let in_hand = ref None in
  let finish () =
    Eio.Cancel.protect (fun () ->
      Option.iter unhandled !in_hand;
      List.iter unhandled (end_and_drain t))
  in
  let rec loop () =
    let op = Eio.Stream.take t.ops in
    in_hand := Some op;
    let next = handle op in
    in_hand := None;
    match next with
    | `Continue -> loop ()
    | `Finished -> ()
  in
  match loop () with
  | () -> finish ()
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    finish ();
    Printexc.raise_with_backtrace exn backtrace
;;
