(** HITL (human-in-the-loop) approval configuration. *)

val critical_timeout_s : unit -> float
(** Critical-tool approval timeout in seconds.

    Env: [MASC_HITL_CRITICAL_TIMEOUT_S]. Default: [3600.0] (1 hour).
    Values <= [0.0] disable the timeout and revert to the legacy
    operator-must-decide behavior (warned once at module load). *)
