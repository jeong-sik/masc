(** SSOT for OS-level / runtime error classification surfaced to MASC
    fleet reactors (FD pressure circuit breaker, disk pressure circuit
    breaker, dashboard coverage-gap hint).

    RFC-0154 §3.1.

    A new named variant is added only when (a) a backend reactor exists
    for the failure mode and (b) a canonical RFC describes the operator
    remediation.  Otherwise the original message is preserved verbatim
    in [Other s] — parse-don't-validate escape hatch, not a catch-all. *)

type t =
  | Fd_exhaustion
      (** RFC-0097.  [Unix.EMFILE] / [Unix.ENFILE], or substrings
          ["too many open files"], ["emfile"], ["enfile"],
          ["file descriptor"], ["os error 24"]. *)
  | Disk_exhaustion
      (** RFC-0122.  [Unix.ENOSPC], or substrings
          ["no space left on device"], ["enospc"],
          ["disk quota exceeded"], ["quota exceeded"], ["disk full"],
          ["not enough space"]. *)
  | Permission_denied
      (** [Unix.EACCES] / [Unix.EPERM], or substrings
          ["permission denied"], ["eacces"], ["eperm"],
          ["operation not permitted"]. *)
  | Connection_refused
      (** [Unix.ECONNREFUSED], or substrings ["connection refused"],
          ["econnrefused"]. *)
  | Timeout
      (** [Unix.ETIMEDOUT], or substrings ["etimedout"], ["timed out"],
          ["operation timed out"]. *)
  | Other of string
      (** Unclassified error.  The string is the verbatim input that
          [classify_string] received, preserving original casing. *)

val classify_exn : exn -> t
(** Errno match on [Unix.Unix_error _] takes priority.  Other
    exceptions fall through to [classify_string (Printexc.to_string exn)]. *)

val classify_string : string -> t
(** Case-insensitive substring match against the unified vocabulary.
    Returns [Other s] (original casing preserved) when no class matches. *)

val to_short_tag : t -> string
(** Stable wire-format tag.  Returns one of:
    ["fd_exhaustion"], ["disk_exhaustion"], ["permission_denied"],
    ["connection_refused"], ["timeout"], ["other"]. *)

val to_raw_text : t -> string
(** Display text.  Named variants return their short tag; [Other s]
    returns [s] verbatim. *)
