(** Comment rate limiting: per-author sliding-window tracker.

    Module-level [Hashtbl] (no internal locking); callers must already
    hold [board_core] [with_lock store]. *)

(** [check ~author ~now] returns [Some retry_after_sec] if [author]
    has already posted [Limits.comment_rate_limit] comments in the
    last [Limits.comment_rate_window_sec] seconds (with [retry_after]
    rounded up by 1.0s for client clarity); [None] otherwise. When
    [Limits.comment_rate_limit <= 0] (rate limiting disabled), always
    returns [None]. *)
val check : author:string -> now:float -> float option

(** [record ~author ~now] appends [now] to [author]'s timestamp list.
    Callers should invoke this AFTER a successful comment is persisted
    (and AFTER [check] returns [None]) — otherwise the windows can
    drift across concurrent attempts. *)
val record : author:string -> now:float -> unit

(** [reset ()] clears the tracker entirely. Test-only. *)
val reset : unit -> unit

(** [sweep_stale ~now ~window] expires per-author timestamps older
    than [window] seconds from [now] and removes any author whose list
    became empty. Called from the board-core sweep loop. *)
val sweep_stale : now:float -> window:float -> unit
