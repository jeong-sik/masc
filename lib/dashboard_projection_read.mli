(** Metadata read policy shared below the Dashboard and operator libraries. *)

type t = Reuse | Current
(** [Reuse] permits the existing stale-while-revalidate caches. [Current]
    observes authoritative metadata for a source-triggered computation, so a
    healthy worker cannot settle on a previous generation's cached answer. *)
