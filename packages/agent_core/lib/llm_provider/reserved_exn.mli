(** Reserved exceptions that observer-isolation wrappers must not absorb.

    Callback isolation sites (introduced for stream observers in #2036)
    catch exceptions raised by user-supplied callbacks, log them, and
    continue so a buggy observer cannot abort a run.  Four exceptions are
    exempt and always propagate:

    - [Out_of_memory], [Stack_overflow], [Sys.Break] — runtime conditions
      that must not be swallowed
    - [Eio.Cancel.Cancelled] — absorbing it breaks structured cancellation

    Standard cleanup/parallelism wrappers do not make a reserved cause safe
    to discard: [Fun.Finally_raised] and [Eio.Exn.Multiple] are also reserved
    when they contain one of these causes. A mixed aggregate propagates in
    full, retaining its other errors rather than turning cancellation into
    success or erasing a co-occurring failure.

    @since 0.206.8 *)

(** [reraise_if_reserved exn] re-raises [exn] (preserving its backtrace)
    when it contains one of the reserved exceptions above; returns [()] for any
    other exception.  Call it first inside a catch-all handler, before
    logging and dropping the exception. *)
val reraise_if_reserved : exn -> unit
