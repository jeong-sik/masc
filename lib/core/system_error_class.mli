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

(** The errnos MASC acts on, as a closed sum of our own.

    [Unix.error] is a foreign closed variant with far more constructors than
    any call site decides on.  Call sites must not match on its constructors
    with a catch-all arm, because a constructor added by a new OCaml release
    would silently take that arm.  [errno_of_unix_error] is the only place
    that lists every [Unix.error] constructor; call sites match on [errno]
    and name each case, so a case added here is a compile error at every
    site that has to decide on it. *)
type errno =
  | Emfile  (** Per-process file descriptor table is full. *)
  | Enfile  (** System-wide file table is full. *)
  | Enospc  (** No space left on the device. *)
  | Eacces  (** Permission denied. *)
  | Eperm  (** Operation not permitted. *)
  | Enoent  (** No such file or directory. *)
  | Econnrefused  (** Connection refused. *)
  | Etimedout  (** Connection or operation timed out. *)
  | Epipe  (** The reader of a pipe or socket has closed it. *)
  | Eaddrinuse  (** The address is already in use. *)
  | Eaddrnotavail  (** The address is not available on this host. *)
  | Other_errno of Unix.error
      (** Any other errno, carried unchanged so no information is lost. *)

val errno_of_unix_error : Unix.error -> errno
(** Total over [Unix.error]: every constructor is listed in the
    implementation, with no catch-all arm. *)

val errno_of_exn : exn -> errno option
(** [Some _] for [Unix.Unix_error]; [None] for every other exception.  Text
    carried by [Sys_error] or [Failure] is not parsed here; use
    [classify_exn] for that. *)

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
