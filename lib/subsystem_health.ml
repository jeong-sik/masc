(** Subsystem health registry.
    Tracks which forked subsystems are alive or have crashed.
    Module-level Hashtbl: available from process start, no init timing dependency.
    Called by fork_subsystem in server_runtime_bootstrap, queried by /health.

    [register] runs when a subsystem fiber is forked, [mark_dead] when a
    supervisor fiber observes the crash, and [to_yojson] from the HTTP
    /health handler — three different fibers.  Without a mutex the
    Hashtbl writes race and [to_yojson]'s fold can observe a half-written
    state.  [Stdlib.Mutex] because the registry is read from the /health
    handler which may run on a different domain than the fork callers. *)

let registry : (string, bool * float option) Hashtbl.t = Hashtbl.create 8
let registry_mu = Stdlib.Mutex.create ()

let with_lock f =
  Stdlib.Mutex.lock registry_mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock registry_mu) f
;;

let register name = with_lock (fun () -> Hashtbl.replace registry name (true, None))

let mark_dead name =
  with_lock (fun () -> Hashtbl.replace registry name (false, Some (Time_compat.now ())))
;;

let to_yojson () : Yojson.Safe.t =
  let entries =
    with_lock (fun () ->
      Hashtbl.fold
        (fun name (alive, crash_time) acc ->
           let status = if alive then "alive" else "dead" in
           let fields =
             [ "status", `String status ]
             @
             match crash_time with
             | Some t -> [ "crashed_at", `Float t ]
             | None -> []
           in
           (name, `Assoc fields) :: acc)
        registry
        [])
  in
  `Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) entries)
;;
