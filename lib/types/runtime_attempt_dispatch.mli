(** Whether a runtime-lane candidate attempt reached its provider or client.

    The runtime walk refuses some candidates before invoking anything (a
    candidate missing from the runtime table, a tool surface the candidate
    cannot carry, a provider config it cannot dispatch under). Those refusals
    are typed attempt errors like any other, but the error is the walk's own
    verdict, not the candidate's answer. Consumers that attribute an error to
    the runtime that produced it read this value; the error alone cannot tell
    the two apart.

    Lives in [masc_types] so both the keeper walk (library [masc]) and the
    task-side reviewer hook ([masc.task_handlers], which [masc] depends on)
    name the same closed sum. [Keeper_attempt_dispatch] in the keeper layer
    re-exports it. *)

type t =
  | Dispatched
      (** The candidate's provider or client was invoked. The attempt error,
          if any, is that candidate's answer. *)
  | Rejected_before_dispatch
      (** The walk refused the candidate without invoking it. The attempt
          error names the refusal; no provider saw the request. *)

(** Log rendering: ["dispatched"] or ["rejected_before_dispatch"]. *)
val to_string : t -> string
