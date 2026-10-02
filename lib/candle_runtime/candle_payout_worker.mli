(** The payout worker (RFC-goal-candle-ledger 3.2, step 3).

    One daemon per server. It runs {!Candle_candidates.drain_once} once when it
    starts and again each time it is woken. Nothing wakes it by a timer of its
    own: the operator's confirmation wakes it, and so does the maintenance tick,
    which is how source and transport failures are tried again. Each Goal has
    at most one in-flight appraisal fiber, so a slow provider does not block
    another Goal. Invalid responses wait for an event wake. A wake that
    arrives while a pass runs is kept, so no pass misses it. *)

val start : ?appraiser_declaration_changed:(unit -> bool) -> sw:Eio.Switch.t -> appraise:Candle_appraisal.runner -> config:Workspace_utils_backend_setup.config -> unit -> unit
(** Starts the daemon in [sw]. A second start for the same base path is
    refused with a log line, and so is a start for another base path while one
    runs. The daemon stops with [sw]. A changed appraiser declaration releases
    rejection on the next enabled pass, including a change seen in flight. *)

val wake : unit -> unit
(** Asks the running worker for one more pass. Does nothing when none runs. *)

val pulse : unit -> unit
(** Maintenance retries source/transport failures, and reconsiders rejection
    when the supplied probe reports a changed appraiser declaration. Otherwise
    invalid output waits for startup, confirmation or another terminal payout. *)
module For_testing : sig val idle : unit -> bool end
