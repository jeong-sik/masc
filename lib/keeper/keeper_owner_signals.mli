(** Signals the Keeper owner raises into a turn, readable by runtime adapters.

    See the implementation for why this module exists separately from
    [Keeper_owner]: the owner calls the adapters, so they cannot depend on it.
    The operator interrupt classifier lives in a lower-level registry module. *)

exception Stop_active_child
(** Server shutdown stops an owner's running turn with this reason. It is
    the same constructor as [Posix_spawn_process_mgr.Stop_without_grace]:
    the turn is abandoned, so the processes it started end with SIGKILL and
    no TERM grace (#49684). *)

val is_owner_cancel_reason : exn -> bool
(** Classify a cancellation exception, including Eio wrapper and combined
    shapes. Both owner shutdown and operator interrupt are deliberate stops;
    an unrelated or mixed cancellation remains ambiguous to the native
    session store. *)
