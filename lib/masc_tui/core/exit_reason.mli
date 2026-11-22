(** Session exit reason vocabulary preserving the [[masc-tui] exit: <reason>]
    wire format expected by [scripts/tui-graceful-restart.sh] and release CI. *)

type t =
  | Quit_key
  | Interrupt
  | Terminate of string
  | Exception of string
  | Unrecorded

val wire_prefix : string
(** ["[masc-tui] "] *)

val label : t -> string
(** Cause text without the normal/abnormal classification. *)

val is_normal : t -> bool
(** [true] for intentional exits ([Quit_key], [Interrupt], [Terminate _]). *)

val line : t -> string
(** Unprefixed exit line, e.g. ["exit: normal (quit key)"]. *)

val wire_line : t -> string
(** Full stderr log line, e.g. ["[masc-tui] exit: normal (signal SIGTERM)"]. *)

val equal : t -> t -> bool
