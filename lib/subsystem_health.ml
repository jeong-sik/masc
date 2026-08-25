(** Subsystem health registry.
    Tracks which forked subsystems are alive or have crashed.
    Module-level immutable state: available from process start, no init timing dependency.
    Called by fork_subsystem in server_runtime_bootstrap, queried by /health.

    [register] runs when a subsystem fiber is forked, [mark_dead] when a
    supervisor fiber observes the crash, and [to_yojson] from the HTTP
    /health handler — three different fibers. [Stdlib.Mutex] protects only
    the state swap/snapshot because the registry may cross domains; clock
    observation and JSON rendering stay outside the critical section. *)

module State = Subsystem_health_state

let state = ref State.empty
let registry_mu = Stdlib.Mutex.create ()

let apply event =
  Stdlib.Mutex.protect registry_mu (fun () ->
    state := State.apply !state event)
;;

let register name = apply (State.Registered { name })

let mark_dead name =
  let crashed_at = Time_compat.now () in
  apply (State.Crashed { name; crashed_at })
;;

let to_yojson () : Yojson.Safe.t =
  let snapshot = Stdlib.Mutex.protect registry_mu (fun () -> !state) in
  let entry_to_json (name, health) =
    let fields =
      match health with
      | State.Alive -> [ "status", `String "alive" ]
      | State.Dead { crashed_at } ->
        [ "status", `String "dead"; "crashed_at", `Float crashed_at ]
    in
    name, `Assoc fields
  in
  `Assoc (List.map entry_to_json (State.entries snapshot))
