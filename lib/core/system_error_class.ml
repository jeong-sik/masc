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
  ; "fd leak"
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

type errno =
  | Emfile
  | Enfile
  | Enospc
  | Eacces
  | Eperm
  | Enoent
  | Econnrefused
  | Etimedout
  | Epipe
  | Eaddrinuse
  | Eaddrnotavail
  | Other_errno of Unix.error

(* The only match in the tree that lists every [Unix.error] constructor.  It
   has no catch-all arm, so an OCaml release that adds a constructor fails to
   compile here and nowhere else. *)
let errno_of_unix_error (code : Unix.error) =
  match code with
  | Unix.EMFILE -> Emfile
  | Unix.ENFILE -> Enfile
  | Unix.ENOSPC -> Enospc
  | Unix.EACCES -> Eacces
  | Unix.EPERM -> Eperm
  | Unix.ENOENT -> Enoent
  | Unix.ECONNREFUSED -> Econnrefused
  | Unix.ETIMEDOUT -> Etimedout
  | Unix.EPIPE -> Epipe
  | Unix.EADDRINUSE -> Eaddrinuse
  | Unix.EADDRNOTAVAIL -> Eaddrnotavail
  | ( Unix.E2BIG | Unix.EAGAIN | Unix.EBADF | Unix.EBUSY | Unix.ECHILD
    | Unix.EDEADLK | Unix.EDOM | Unix.EEXIST | Unix.EFAULT | Unix.EFBIG
    | Unix.EINTR | Unix.EINVAL | Unix.EIO | Unix.EISDIR | Unix.EMLINK
    | Unix.ENAMETOOLONG | Unix.ENODEV | Unix.ENOEXEC | Unix.ENOLCK
    | Unix.ENOMEM | Unix.ENOSYS | Unix.ENOTDIR | Unix.ENOTEMPTY | Unix.ENOTTY
    | Unix.ENXIO | Unix.ERANGE | Unix.EROFS | Unix.ESPIPE
    | Unix.ESRCH | Unix.EXDEV | Unix.EWOULDBLOCK | Unix.EINPROGRESS
    | Unix.EALREADY | Unix.ENOTSOCK | Unix.EDESTADDRREQ | Unix.EMSGSIZE
    | Unix.EPROTOTYPE | Unix.ENOPROTOOPT | Unix.EPROTONOSUPPORT
    | Unix.ESOCKTNOSUPPORT | Unix.EOPNOTSUPP | Unix.EPFNOSUPPORT
    | Unix.EAFNOSUPPORT
    | Unix.ENETDOWN | Unix.ENETUNREACH | Unix.ENETRESET | Unix.ECONNABORTED
    | Unix.ECONNRESET | Unix.ENOBUFS | Unix.EISCONN | Unix.ENOTCONN
    | Unix.ESHUTDOWN | Unix.ETOOMANYREFS | Unix.EHOSTDOWN | Unix.EHOSTUNREACH
    | Unix.ELOOP | Unix.EOVERFLOW | Unix.EUNKNOWNERR _ ) as other ->
    Other_errno other

let errno_of_exn = function
  | Unix.Unix_error (code, _, _) -> Some (errno_of_unix_error code)
  | _ -> None

let classify_exn exn =
  match errno_of_exn exn with
  | Some (Emfile | Enfile) -> Fd_exhaustion
  | Some Enospc -> Disk_exhaustion
  | Some (Eacces | Eperm) -> Permission_denied
  | Some Econnrefused -> Connection_refused
  | Some Etimedout -> Timeout
  | Some (Enoent | Epipe | Eaddrinuse | Eaddrnotavail | Other_errno _) | None -> classify_string (Printexc.to_string exn)

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
