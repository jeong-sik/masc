type t =
  { name : string
  ; lock : Mutex.t
  }

type suspension =
  | Suspend
  | Fork
  | Run_in_systhread
  | Await_readable
  | Await_writable
  | Other

type record =
  { mutex_name : string
  ; suspension : suspension
  ; performed_at : Printexc.raw_backtrace
  ; protect_called_at : Printexc.raw_backtrace
  }

exception
  Held_across_suspension of
    { record : record
    ; body_raised : (exn * Printexc.raw_backtrace) option
    }

(* Frames kept from each stack: enough to climb out of Eio's own frames to
   the code that took the lock. *)
let stack_depth = 32

let create ~name () = { name; lock = Mutex.create () }

(* No handler answers [Get_context] outside an Eio scheduler. *)
let in_eio () =
  match Effect.perform Eio.Private.Effects.Get_context with
  | (_ : Eio.Private.Fiber_context.t) -> true
  | exception Effect.Unhandled _ -> false
;;

(* The first eight cases are the effects Eio 1.3 and eio_posix 1.3 answer
   without switching fibers; RFC D2 cites where each one is answered. Every
   other effect switches. [Effect.t] is open, so the last case must stay: an
   effect this module cannot name is counted as switching, which fails loudly
   instead of passing silently. *)
let suspension_of (type a) (eff : a Effect.t) =
  match eff with
  | Eio.Private.Effects.Get_context -> None
  | Eio_unix.Private.Get_monotonic_clock -> None
  | Eio_unix.Private.Pipe _ -> None
  | Eio_unix.Net.Import_socket_stream _ -> None
  | Eio_unix.Net.Import_socket_listening _ -> None
  | Eio_unix.Net.Import_socket_datagram _ -> None
  | Eio_unix.Net.Socketpair_stream _ -> None
  | Eio_unix.Net.Socketpair_datagram _ -> None
  | Eio.Private.Effects.Suspend _ -> Some Suspend
  | Eio.Private.Effects.Fork _ -> Some Fork
  | Eio_unix.Private.Thread_pool.Run_in_systhread _ -> Some Run_in_systhread
  | Eio_unix.Private.Await_readable _ -> Some Await_readable
  | Eio_unix.Private.Await_writable _ -> Some Await_writable
  | _ -> Some Other
;;

let suspension_name = function
  | Suspend -> "Suspend"
  | Fork -> "Fork"
  | Run_in_systhread -> "Run_in_systhread"
  | Await_readable -> "Await_readable"
  | Await_writable -> "Await_writable"
  | Other -> "an effect Os_mutex cannot name"
;;

let frames backtrace =
  match Printexc.raw_backtrace_length backtrace with
  | 0 -> "  (no frames)\n"
  | _ -> Printexc.raw_backtrace_to_string backtrace
;;

let record_to_string record =
  Printf.sprintf
    "Os_mutex %S: its Eio fiber switched while holding it (%s).\n\
     performed at:\n\
     %sprotect called at:\n\
     %s"
    record.mutex_name
    (suspension_name record.suspension)
    (frames record.performed_at)
    (frames record.protect_called_at)
;;

(* One write and a flush before the effect is forwarded, so a section that
   never ends still leaves this behind. A stderr that cannot be written loses
   only this early copy: the record still rides on [Held_across_suspension]
   when the section ends. Raising here instead would drop the continuation
   with the effect unforwarded, and an Eio primitive that suspends under its
   own lock would keep that lock. *)
let write_early_copy record =
  match
    output_string stderr (record_to_string record);
    flush stderr
  with
  | () -> ()
  | exception Sys_error _ -> ()
;;

type 'a ended =
  | Returned of 'a
  | Raised of exn * Printexc.raw_backtrace

(* Runs [f] under a handler that forwards every effect to the handler
   outside it. Returns how [f] ended, and the record of the switching effect
   that marked the section, if one did. *)
let run_section mutex_name f =
  let marked = ref None in
  let ended =
    Effect.Deep.match_with
      f
      ()
      { retc = (fun value -> Returned value)
      ; exnc = (fun exn -> Raised (exn, Printexc.get_raw_backtrace ()))
      ; effc =
          (fun (type c) (eff : c Effect.t) ->
            match !marked, suspension_of eff with
            | Some _, _ | None, None -> None
            | None, Some suspension ->
              Some
                (fun (k : (c, _) Effect.Deep.continuation) ->
                  let record =
                    { mutex_name
                    ; suspension
                    ; performed_at = Effect.Deep.get_callstack k stack_depth
                    ; protect_called_at = Printexc.get_callstack stack_depth
                    }
                  in
                  write_early_copy record;
                  match Effect.perform eff with
                  | value ->
                    marked := Some record;
                    Effect.Deep.continue k value
                  | exception (Effect.Unhandled _ as exn) ->
                    (* Nothing outside answered it, so the fiber never
                       switched: the section is not marked. *)
                    Effect.Deep.discontinue_with_backtrace
                      k
                      exn
                      (Printexc.get_raw_backtrace ())
                  | exception exn ->
                    let backtrace = Printexc.get_raw_backtrace () in
                    marked := Some record;
                    Effect.Deep.discontinue_with_backtrace k exn backtrace))
      }
  in
  !marked, ended
;;

let finish marked ended =
  match marked, ended with
  | None, Returned value -> value
  | None, Raised (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
  | Some _, Raised ((Eio.Cancel.Cancelled _ as exn), backtrace) ->
    (* Eio does not report a cancellation; the record is on stderr. *)
    Printexc.raise_with_backtrace exn backtrace
  | Some record, Returned _ ->
    raise (Held_across_suspension { record; body_raised = None })
  | Some record, Raised (exn, backtrace) ->
    raise (Held_across_suspension { record; body_raised = Some (exn, backtrace) })
;;

(* The caller holds [t.lock]. It is released before this returns or
   raises. *)
let run_locked t f =
  match in_eio () with
  | true ->
    (match run_section t.name f with
     | marked, ended ->
       Mutex.unlock t.lock;
       finish marked ended
     | exception exn ->
       (* Raised by the handler itself, such as an asynchronous exception. *)
       let backtrace = Printexc.get_raw_backtrace () in
       Mutex.unlock t.lock;
       Printexc.raise_with_backtrace exn backtrace)
  | false ->
    (match f () with
     | value ->
       Mutex.unlock t.lock;
       value
     | exception exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       Mutex.unlock t.lock;
       Printexc.raise_with_backtrace exn backtrace)
;;

let protect t f =
  Mutex.lock t.lock;
  run_locked t f
;;

let try_protect t f =
  match Mutex.try_lock t.lock with
  | true -> Some (run_locked t f)
  | false -> None
;;

let wait condition t = Condition.wait condition t.lock

let () =
  Printexc.register_printer (function
    | Held_across_suspension { record; body_raised } ->
      let body =
        match body_raised with
        | None -> ""
        | Some (exn, _) -> "; the section raised " ^ Printexc.to_string exn
      in
      Some
        (Printf.sprintf
           "Os_mutex.Held_across_suspension: %S was held while its Eio fiber \
            switched (%s)%s"
           record.mutex_name
           (suspension_name record.suspension)
           body)
    | _ -> None)
;;
