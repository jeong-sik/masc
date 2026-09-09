type socket = [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t

module Owned_socket = struct
  type tag = [ `Generic ]
  type t = { socket : socket; close : unit -> unit }

  let read_methods = []
  let single_read t = Eio.Flow.single_read t.socket
  let single_write t = Eio.Flow.single_write t.socket
  let copy t ~src = Eio.Flow.copy src t.socket
  let shutdown t = Eio.Flow.shutdown t.socket
  let close t = t.close ()
end

let owned_socket_ops = Eio.Net.Pi.stream_socket (module Owned_socket)

(* Eio backends may register the FD on [sw] before connect succeeds. A failed
   attempt must therefore have its own switch, even when the caller's cache
   switch lives for hours. A daemon keeps that scope alive only for the winner;
   unlike an ordinary fiber it cannot prevent normal cache-switch shutdown. *)
let connect_owned ~sw ~net address : socket =
  Eio.Switch.check sw;
  let ready, publish = Eio.Promise.create () in
  let released, release = Eio.Promise.create () in
  let finished, finish = Eio.Promise.create () in
  let closing = Atomic.make false in
  let close () =
    Eio.Cancel.protect (fun () ->
      if Atomic.compare_and_set closing false true then Eio.Promise.resolve release ();
      Eio.Promise.await finished)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let outcome =
      try
        Eio.Fiber.first
          (fun () ->
            Eio.Switch.run (fun attempt_sw ->
              let socket = Eio.Net.connect ~sw:attempt_sw net address in
              Eio.Promise.resolve publish (Ok (socket :> socket));
              Eio.Promise.await released))
          (fun () -> Eio.Promise.await released);
        Ok ()
      with exn -> Error (exn, Printexc.get_raw_backtrace ())
    in
    Eio.Promise.resolve finish ();
    match outcome with
    | Ok () -> `Stop_daemon
    | Error ((Eio.Cancel.Cancelled _ as exn), bt) ->
      if not (Eio.Promise.is_resolved ready)
      then Eio.Promise.resolve publish (Error (exn, bt));
      `Stop_daemon
    | Error (exn, bt) ->
      if Eio.Promise.is_resolved ready
      then Printexc.raise_with_backtrace exn bt
      else (
        Eio.Promise.resolve publish (Error (exn, bt));
        `Stop_daemon));
  match Eio.Promise.await ready with
  | Ok socket -> Eio.Resource.T ({ Owned_socket.socket; close }, owned_socket_ops)
  | Error (exn, bt) ->
    close ();
    Printexc.raise_with_backtrace exn bt
  | exception exn ->
    let bt = Printexc.get_raw_backtrace () in
    close ();
    Printexc.raise_with_backtrace exn bt

let connect ~sw ~net addresses =
  match addresses with
  | [] -> invalid_arg "TCP address racing requires a resolved address"
  | _ ->
    let failures = Array.make (List.length addresses) None in
    let remaining = ref (Array.length failures) in
    let connected = ref [] in
    let attempt index address () =
      match connect_owned ~sw ~net address with
      | socket -> connected := socket :: !connected; socket
      | exception ((Eio.Io _ | Unix.Unix_error _) as exn) ->
        failures.(index) <- Some (exn, Printexc.get_raw_backtrace ());
        decr remaining;
        if !remaining = 0
        then (
          match failures.(Array.length failures - 1) with
          | Some (last, bt) -> Printexc.raise_with_backtrace last bt
          | None -> assert false)
        else Eio.Fiber.await_cancel ()
    in
    match
      Eio.Fiber.any
        ~combine:(fun winner other -> Eio.Resource.close other; winner)
        (List.mapi attempt addresses)
    with
    | winner -> winner
    | exception exn ->
      let bt = Printexc.get_raw_backtrace () in
      (* A winner can race with cancellation of the caller itself. [any]
         correctly propagates cancellation then, but cannot own our sockets. *)
      List.iter Eio.Resource.close !connected;
      Printexc.raise_with_backtrace exn bt
