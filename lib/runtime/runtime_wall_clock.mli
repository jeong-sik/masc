(** Whole-turn wall-clock ceiling shared by the official-client CLI runtimes
    (antigravity, claude_code, codex_app_server).

    Their per-operation idle timeouts reset on every emitted line, so a CLI
    that keeps emitting inside each window holds the turn indefinitely. This
    ceiling bounds the whole turn regardless of emitted output. A turn that
    hits it terminates through the runtime's existing typed [Timeout] error —
    this module adds no new disposition. *)

val default_ceiling_s : float
(** Hours-scale on purpose so it never competes with the progress-axis
    deadlines: a healthy turn's progress gaps top out around 120s and the
    model rows budget 600s per phase. *)

type t

val make : ?ceiling_s:float -> now:(unit -> float) -> unit -> t
(** [make ~now ()] starts the ceiling at [now ()]. [now] is the caller's
    clock, so the ceiling holds no ambient time source. *)

val expired : t -> bool

val cap_window : t -> float option -> float option
(** Cap a per-operation idle window so an in-flight read or write cannot
    outlive the ceiling by up to one idle window. [None] (no idle deadline
    requested) still yields the remaining budget: the ceiling is always a
    deadline, never a request. *)
