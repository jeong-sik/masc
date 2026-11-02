(* Store callbacks may run outside Eio and must not wait for SSE fanout.
   Keep one pending and one active publication per workspace. A publisher
   waiting cooperatively does not prevent another workspace from starting. *)
let start ~sw ~mono_clock ~publish =
  let pending = ref Set_util.StringSet.empty in
  let active = ref Set_util.StringSet.empty in
  let wake = Eio.Stream.create 1 in
  let mu = Stdlib.Mutex.create () in
  let signal_locked () =
    if Eio.Stream.is_empty wake then Eio.Stream.add wake () in
  let enqueue ~base_path =
    Stdlib.Mutex.protect mu (fun () ->
      pending := Set_util.StringSet.add base_path !pending;
      signal_locked ())
  in
  let finish base_path =
    Stdlib.Mutex.protect mu (fun () ->
      active := Set_util.StringSet.remove base_path !active;
      if not (Set_util.StringSet.is_empty (Set_util.StringSet.diff !pending !active))
      then signal_locked ())
  in
  (* Bound retries after a transport failure; an idle source has no timer. *)
  let retry_initial_s = 1.0 in
  let retry_ceiling_s = 60.0 in
  let publish_one base_path =
    let rec attempt delay =
      match publish ~base_path with
      | () -> ()
      | exception exn ->
        (match exn with
         | Eio.Cancel.Cancelled _ -> Eio.Fiber.check ()
         | _ -> ());
        (* A transport exception can contain source data; the event itself
           carries no rows, and logs must not expose confirmation tokens. *)
        Log.Server.warn "workspace invalidation publish failed; retrying";
        Eio.Time.Mono.sleep mono_clock delay;
        attempt (Float.min retry_ceiling_s (delay *. 2.0))
    in
    Fun.protect ~finally:(fun () -> finish base_path)
      (fun () -> attempt retry_initial_s)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      Eio.Stream.take wake;
      let paths = Stdlib.Mutex.protect mu (fun () ->
        let paths = Set_util.StringSet.diff !pending !active in
        pending := Set_util.StringSet.diff !pending paths;
        active := Set_util.StringSet.union !active paths;
        paths) in
      Set_util.StringSet.iter (fun base_path ->
        Eio.Fiber.fork_daemon ~sw (fun () ->
          publish_one base_path;
          `Stop_daemon)) paths;
      loop () in
    loop ());
  enqueue
;;
