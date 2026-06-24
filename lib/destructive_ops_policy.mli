(** Destructive operations policy — typed TOML-backed catalogue.

    The canonical destructive-pattern list lives in
    [config/destructive_ops.toml]. That file is embedded into the binary
    at build time via [masc.embedded_config]; the {!default} value reads
    it from the embedded copy. Runtime loaders can also read a workspace
    copy from the filesystem.

    Enforcement code receives a [t] as an argument (dependency injection)
    rather than consulting a hard-coded module-level list. *)

(** {1 Types} *)

type destructive_class = Shell_safety_types.destructive_class =
  | Recursive_delete
  | Sql_destructive
  | Forced_git_mutation
  | Privilege_escalation
  | Filesystem_format
  | Device_write
  | Process_signal
  | System_control

type destructive_pattern = Shell_safety_types.destructive_pattern = {
  class_ : destructive_class;
  pattern : string;
  description : string;
}

type t
(** Opaque loaded policy. Immutable. *)

type load_error = {
  path : string;  (** TOML path where the error occurred *)
  message : string;
}
[@@deriving show]

(** {1 Constructors} *)

val default : t
(** Policy read from the embedded [config/destructive_ops.toml].
    Raises [Failure] only if the embedded catalogue is malformed, which
    is a build-time bug and must fail fast. *)

val of_patterns : enabled:bool -> destructive_pattern list -> t
(** Build a policy from an explicit list. Used by tests and by callers
    that compose a policy programmatically. [enabled = false] disables
    destructive-pattern detection without changing the catalogue. *)

(** {1 Accessors} *)

val enabled : t -> bool
val patterns : t -> destructive_pattern list

(** {1 TOML loaders} *)

val load_string : string -> (t, load_error list) result
(** Parse a TOML string into a policy. Returns [Ok policy] on success or
    [Error errors] with every validation error found. *)

val load_file : string -> (t, load_error list) result
(** Read a TOML file and parse it. File I/O failures are reported as a
    single [load_error] with path ["<file>:io"]. *)
