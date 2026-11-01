(** One physical Board image preparation at a time. Cancellation of the
    waiting fiber does not imply that its system-thread work has returned. *)
type t
val create : unit -> t
val run : t -> (unit -> ('a, string) result) -> ('a, string) result
(** Refuse another preparation while the original worker is still running.
    The original worker releases its own slot on return or exception. *)
