(** The payout worker (RFC-goal-candle-ledger 3.2, step 3).

    One daemon per server. It runs {!Candle_candidates.drain_once} once when it
    starts and again each time it is woken. Nothing wakes it by a timer of its
    own: the operator's confirmation wakes it, and so does the maintenance tick,
    which is how a payout that could not be prepared is tried again. A wake that
    arrives while a pass runs is kept, so no pass misses it. *)

val start : sw:Eio.Switch.t -> config:Workspace_utils_backend_setup.config -> unit
(** Starts the daemon in [sw]. A second start for the same base path is
    refused with a log line, and so is a start for another base path while one
    runs. The daemon stops with [sw]. *)

val wake : unit -> unit
(** Asks the running worker for one more pass. Does nothing when none runs. *)
