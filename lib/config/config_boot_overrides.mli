(** Process-local boot override store.

    Holds startup-loaded configuration that readers consult without mutating
    the real process environment.

    Precedence used by {!source} and standard readers:
    real process env > boot override store > hardcoded default. A file-owned
    name (see {!declare_file_owned}) skips the process env: boot override
    store > hardcoded default.

    The backing [StringMap] and the [Atomic.t] cell are intentionally
    hidden — callers interact only through the [get/set/clear/source]
    surface. *)

val get_opt : string -> string option
(** Read the boot override for [name]. [None] if no override is set. *)

val set : string -> string -> unit
(** Set a boot override. CAS-based; safe under contention. *)

val clear : string -> unit
(** Drop the boot override for [name]. CAS-based. *)

val declare_file_owned : string list -> unit
(** Declare the names whose only input is the runtime file; replaces any earlier
    declaration. The loader calls it at boot with the registry's file-owned
    names, before it reads or applies anything, and with [[]] when the file
    does not load. A name read before the declaration is read with the process
    env first. *)

val is_file_owned : string -> bool
(** Whether [name] was declared file-owned. *)

val reset_for_tests : unit -> unit
(** Test-only: reset the entire store, including the file-owned declaration,
    to empty. *)

(** The layer that would supply a setting: the process environment, the
    boot-time override the runtime file applied, or neither. *)
type source =
  | Env
  | Boot_override
  | Default

val source : string -> source
(** The layer that would supply [name]. *)

val source_to_string : source -> string
(** ["env"] | ["boot_override"] | ["default"], the labels the feature-flag
    projection reports. *)
