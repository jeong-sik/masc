(** One physical Board image preparation at a time. Cancellation of the
    waiting fiber does not imply that its system-thread work has returned. *)
type t
val create : unit -> t
val is_busy : t -> bool
val try_acquire : t -> bool
val release : t -> unit
(** For an asynchronous child, acquire before spawning and release only after
    its physical process has been reaped. *)
val run : t -> (unit -> ('a, string) result) -> ('a, string) result
(** Refuse another preparation while the original worker is still running.
    The original worker releases its own slot on return or exception. *)
