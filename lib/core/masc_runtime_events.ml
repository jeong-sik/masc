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

let is_decimal_digits s =
  s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s

(* The runtime names its buffer with a plain decimal pid, so the stem must be
   exactly that.  [int_of_string_opt] alone is too permissive: it accepts OCaml
   integer literals such as "0x10", "+123" and "1_000", which would let an
   unrelated file like [0x10.events] be mistaken for a dump and unlinked. *)
let dump_pid_of_filename name =
  match Filename.chop_suffix_opt ~suffix:dump_suffix name with
  | None -> None
  | Some stem when is_decimal_digits stem -> int_of_string_opt stem
  | Some _ -> None

(* [OCAML_RUNTIME_EVENTS_PRESERVE] asks the runtime to leave buffers behind for
   later inspection.  Every preserved file has a dead pid by construction, so
   pruning would delete exactly what the operator asked to keep.  The runtime
   checks only for the variable's presence, so this does too. *)
let preserve_requested () =
  Option.is_some (Sys.getenv_opt "OCAML_RUNTIME_EVENTS_PRESERVE")

(* [Unix.kill pid 0] probes existence without signalling.  EPERM means the
   process exists but belongs to another user, so it counts as live; any other
   error is treated as live too, because deleting a buffer a consumer is
   reading from is worse than leaving a file behind. *)
let pid_is_live pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | exception _ -> true  (* cancel-guard-ok: guards a blocking syscall: no Eio cancellation point *)

let prune_stale_dumps ~dir =
  if preserve_requested ()
  then
    Log.Runtime.info
      "OCAML_RUNTIME_EVENTS_PRESERVE set; leaving dumps in %s"
      dir
  else (
    match Sys.readdir dir with
    | exception Sys_error msg ->
      Log.Runtime.warn "cannot scan %s for stale dumps: %s" dir msg
    | entries ->
    (* Identity check only: never unlink our own live buffer. No output value
       depends on the pid, so it is not a determinism input. *)
    (* DET-OK: safety predicate on this process's own identity. *)
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
             Log.Runtime.info
               "removed stale dump %s (pid %d no longer exists)"
               name
               pid
           | exception Sys_error msg ->
             Log.Runtime.warn
               "cannot remove stale dump %s: %s"
               name
               msg))
      entries)

let start_listener () =
  if runtime_events_enabled ()
  then (
    Runtime_events.start ();
    (* Prune after starting, not before: [Runtime_events.path] reports the
       directory the runtime actually chose, which honours
       [OCAML_RUNTIME_EVENTS_DIR].  Reading [Sys.getcwd] instead would scan the
       wrong place whenever that variable is set.  Our own buffer now exists in
       that directory and is skipped by the pid check. *)
    match Runtime_events.path () with
    | Some p -> prune_stale_dumps ~dir:(Filename.dirname p)
    | None ->
      Log.Runtime.warn
        "listener started but path is unavailable; skipping stale-dump prune")
