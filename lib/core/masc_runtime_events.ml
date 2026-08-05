(** Runtime_events event registrations for masc (Wave 2A).

    Registers a user event handle for agent turns and provides a
    start helper so that Olly (or a custom [Runtime_events.Callbacks]
    consumer) can observe both stock OCaml runtime events (GC,
    phases) and masc-specific turn-boundary events.

    The turn event uses [Runtime_events.Type.span] so consumers pair
    [Begin]/[End] bounds natively — no external correlation id is
    required.  Writers bracket the turn body with [with_turn_span] so
    the [Begin]/[End] pair cannot drift apart; [keeper_agent_run]
    keeps a manual pair because its finally is a composite (phase
    event + cancel-ref bookkeeping), not a bare [emit_turn_end]. *)

type Runtime_events.User.tag +=
  | Turn

let ev_turn =
  Runtime_events.User.register "masc.turn"
    Turn Runtime_events.Type.span

let emit_turn_start () =
  Runtime_events.User.write ev_turn Runtime_events.Type.Begin

let emit_turn_end () =
  Runtime_events.User.write ev_turn Runtime_events.Type.End

let with_turn_span f =
  emit_turn_start ();
  Eio_guard.protect ~finally:emit_turn_end f

let runtime_events_enabled () =
  Safe_ops.get_env_bool_logged "MASC_RUNTIME_EVENTS" ~default:true

let dump_suffix = ".events"

let dump_pid_of_filename name =
  match Filename.chop_suffix_opt ~suffix:dump_suffix name with
  | None -> None
  | Some stem -> int_of_string_opt stem

(* [Unix.kill pid 0] probes existence without signalling.  EPERM means the
   process exists but belongs to another user, so it counts as live; any other
   error is treated as live too, because deleting a buffer a consumer is
   reading from is worse than leaving a file behind. *)
let pid_is_live pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | exception _ -> true

let prune_stale_dumps ~dir =
  match Sys.readdir dir with
  | exception Sys_error msg ->
    Log.warn ~ctx:"runtime_events" "cannot scan %s for stale dumps: %s" dir msg
  | entries ->
    (* DET-OK: [getpid] identifies this process so we never unlink the buffer we
       are about to write. It is a safety predicate on our own identity, not an
       input to a computed result — no output depends on its value. *)
    let self = Unix.getpid () in
    (* [readdir] order is unspecified; sort so the emitted log lines are
       reproducible across runs on the same directory. *)
    Array.sort String.compare entries;
    Array.iter
      (fun name ->
        match dump_pid_of_filename name with
        | None -> ()
        | Some pid when pid = self -> ()
        | Some pid when pid_is_live pid -> ()
        | Some pid ->
          let path = Filename.concat dir name in
          (match Sys.remove path with
           | () ->
             Log.info
               ~ctx:"runtime_events"
               "removed stale dump %s (pid %d no longer exists)"
               name
               pid
           | exception Sys_error msg ->
             Log.warn
               ~ctx:"runtime_events"
               "cannot remove stale dump %s: %s"
               name
               msg))
      entries

let start_listener () =
  if runtime_events_enabled ()
  then (
    prune_stale_dumps ~dir:(Sys.getcwd ());
    Runtime_events.start ())
