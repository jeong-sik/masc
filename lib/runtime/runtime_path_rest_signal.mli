(** Says that a record a provider rest or a walk order reads was written
    (RFC-0481 §3.2).

    {!Runtime_candidate_backpressure} calls {!recorded} after
    [note_rate_limit], [note_failed_attempt] and [note_candidate_success];
    {!Runtime_quota_window} after [note_exhausted], [note_observed_exhausted],
    [note_read_without_reset] and [note_succeeded]. Those seven functions are
    the only writers. The call
    carries nothing: the server recomputes the rests it shows and compares.

    The observer runs on the writer's fiber, after the write and outside the
    quota window's mutex. It must be short, must not yield and must not
    raise; the server installs one that only wakes its own fiber. *)

val install : (unit -> unit) -> unit
val recorded : unit -> unit
