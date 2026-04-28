(** Process-local boot override store.

    Holds startup-loaded configuration defaults that behave like
    process-env inputs for readers, without mutating the real process
    environment.

    Precedence used by {!source} and standard readers:
    real process env > boot override store > hardcoded default.

    The backing [StringMap] and the [Atomic.t] cell are intentionally
    hidden — callers interact only through the [get/set/clear/source]
    surface. *)

val get_opt : string -> string option
(** Read the boot override for [name]. [None] if no override is set. *)

val set : string -> string -> unit
(** Set a boot override. CAS-based; safe under contention. *)

val clear : string -> unit
(** Drop the boot override for [name]. CAS-based. *)

val reset_for_tests : unit -> unit
(** Test-only: reset the entire store to empty. *)

val source : string -> string
(** Report which layer would supply [name]: ["env"] | ["boot_override"]
    | ["default"]. *)
