(* RFC-0154 PR-1.  SSOT for OS-level / runtime error classification.
   See system_error_class.mli for the contract.  This module is intentionally
   total and dependency-free (only [String_util] and [Unix]) so that PR-2 can
   thread it through [Telemetry_coverage_gap.record] and the four pre-existing
   inline substring matchers without taking on new transitive deps. *)

type t =
  | Fd_exhaustion
  | Disk_exhaustion
  | Permission_denied
  | Connection_refused
  | Timeout
  | Other of string

(* Vocabulary union of the four pre-existing inline matchers documented in
   RFC-0154 §1.1.  Add a new entry here only when paired with a backend
   reactor + RFC (see .mli docstring). *)

let fd_needles =
  [ "too many open files"
  ; "emfile"
  ; "enfile"
  ; "file descriptor"
  ; "os error 24"
  ; "execve: too many open files"
  ]

let disk_needles =
  [ "no space left on device"
  ; "enospc"
  ; "disk quota exceeded"
  ; "quota exceeded"
  ; "disk full"
  ; "not enough space"
  ]

let permission_needles =
  [ "permission denied"
  ; "eacces"
  ; "eperm"
  ; "operation not permitted"
  ]

let connection_refused_needles = [ "connection refused"; "econnrefused" ]

let timeout_needles = [ "etimedout"; "timed out"; "operation timed out" ]

let any_match s needles = List.exists (String_util.contains_substring_ci s) needles

let classify_string s =
  if String.length s = 0 then Other s
  else if any_match s fd_needles then Fd_exhaustion
  else if any_match s disk_needles then Disk_exhaustion
  else if any_match s permission_needles then Permission_denied
  else if any_match s connection_refused_needles then Connection_refused
  else if any_match s timeout_needles then Timeout
  else Other s

let classify_exn = function
  | Unix.Unix_error ((Unix.EMFILE | Unix.ENFILE), _, _) -> Fd_exhaustion
  | Unix.Unix_error (Unix.ENOSPC, _, _) -> Disk_exhaustion
  | Unix.Unix_error ((Unix.EACCES | Unix.EPERM), _, _) -> Permission_denied
  | Unix.Unix_error (Unix.ECONNREFUSED, _, _) -> Connection_refused
  | Unix.Unix_error (Unix.ETIMEDOUT, _, _) -> Timeout
  | exn -> classify_string (Printexc.to_string exn)

let to_short_tag = function
  | Fd_exhaustion -> "fd_exhaustion"
  | Disk_exhaustion -> "disk_exhaustion"
  | Permission_denied -> "permission_denied"
  | Connection_refused -> "connection_refused"
  | Timeout -> "timeout"
  | Other _ -> "other"

let to_raw_text = function
  | Fd_exhaustion -> "fd_exhaustion"
  | Disk_exhaustion -> "disk_exhaustion"
  | Permission_denied -> "permission_denied"
  | Connection_refused -> "connection_refused"
  | Timeout -> "timeout"
  | Other s -> s
