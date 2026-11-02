(* A store callback may run outside Eio and must not wait for SSE fanout.
   Coalesce pending workspace paths and publish them in a switch-owned fiber. *)
let start ~sw ~publish =
  let pending = ref Set_util.StringSet.empty in
  let wake = Eio.Stream.create 1 in
  let mu = Stdlib.Mutex.create () in
  let enqueue ~base_path =
    Stdlib.Mutex.protect mu (fun () ->
      pending := Set_util.StringSet.add base_path !pending;
      if Eio.Stream.is_empty wake then Eio.Stream.add wake ())
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      Eio.Stream.take wake;
      let paths = Stdlib.Mutex.protect mu (fun () ->
        let paths = !pending in
        pending := Set_util.StringSet.empty;
        paths) in
      Set_util.StringSet.iter (fun base_path ->
        let report exn =
          Log.Server.warn "workspace invalidation publish failed: %s" (Printexc.to_string exn) in
        try publish ~base_path with
        | Eio.Cancel.Cancelled _ as exn -> Eio.Fiber.check (); report exn
        | exn -> report exn) paths;
      loop () in
    loop ());
  enqueue
;;
