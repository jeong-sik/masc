(* RFC-0154 PR-1.  SSOT for OS-level / runtime error classification.
   See system_error_class.mli for the contract.  This module stays total and
   light on dependencies ([String_util], [Unix] and the Eio exception shapes
   this library already links) so that [Telemetry_coverage_gap.record] and the
   pressure reactors can use it without new transitive deps.

   Classifying an exception is structural: the errno is read from
   [Unix.Unix_error] or from the [Eio_unix.Unix_error] backend payload that
   Eio nests inside [Eio.Exn.Io].  Only payloads that are strings by
   construction ([Sys_error], [Failure]) go through [classify_string]; the
   rendered [Printexc.to_string] of an arbitrary exception is never re-parsed
   (constitution [closed_sum_over_string] / [parse_at_boundary], #49742). *)

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

(* Eio keeps the errno of a failed syscall in the [Eio_unix.Unix_error]
   backend payload, nested one of three ways inside [Eio.Exn.Io]: bare as
   [Eio.Exn.X], or under the file-system / network vocabulary [Eio.Fs.E] /
   [Eio.Net.E] (see eio_posix [Err.wrap]).  [Eio.Exn.Backend.t] and
   [Eio.Exn.err] are extensible, so each needs a wildcard arm; the closed
   [Eio.Fs.error] / [Eio.Net.error] vocabularies are listed in full. *)
let errno_of_backend (backend : Eio.Exn.Backend.t) =
  match backend with
  | Eio_unix.Unix_error (code, _, _) -> Some (errno_of_unix_error code)
  | _ -> None

(* The two closed vocabularies get their own matches so that the wildcard arm
   the extensible [err] needs cannot absorb a constructor added to them. *)
let errno_of_fs_error (error : Eio.Fs.error) =
  match error with
  | Eio.Fs.Already_exists backend
  | Eio.Fs.Not_found backend
  | Eio.Fs.Permission_denied backend -> errno_of_backend backend
  | Eio.Fs.File_too_large | Eio.Fs.Not_native _ -> None

let errno_of_net_error (error : Eio.Net.error) =
  match error with
  | Eio.Net.Connection_reset backend
  | Eio.Net.Connection_failure (Eio.Net.Refused backend) -> errno_of_backend backend
  | Eio.Net.Connection_failure (Eio.Net.No_matching_addresses | Eio.Net.Timeout) -> None

let rec errno_of_err (err : Eio.Exn.err) =
  match err with
  | Eio.Exn.X backend -> errno_of_backend backend
  | Eio.Fs.E error -> errno_of_fs_error error
  | Eio.Net.E error -> errno_of_net_error error
  | Eio.Exn.Multiple_io errs -> List.find_map (fun (err, _, _) -> errno_of_err err) errs
  | _ -> None

(* [Eio.Exn.Multiple] reports several failures at once; the first member that
   carries an errno decides, and a cancellation among them contributes none. *)
let rec errno_of_exn = function
  | Unix.Unix_error (code, _, _) -> Some (errno_of_unix_error code)
  | Eio.Exn.Io (err, _) -> errno_of_err err
  | Eio.Exn.Multiple failures -> List.find_map (fun (exn, _) -> errno_of_exn exn) failures
  | _ -> None

let classify_exn exn =
  match errno_of_exn exn with
  | Some (Emfile | Enfile) -> Fd_exhaustion
  | Some Enospc -> Disk_exhaustion
  | Some (Eacces | Eperm) -> Permission_denied
  | Some Econnrefused -> Connection_refused
  | Some Etimedout -> Timeout
  | Some (Enoent | Epipe | Eaddrinuse | Eaddrnotavail | Other_errno _) ->
    (* The errno is the answer and names no class.  The rendered exception is
       kept verbatim, never scanned for a needle that its syscall argument
       (a file name, say) may happen to contain. *)
    Other (Printexc.to_string exn)
  | None ->
    (match exn with
     | Sys_error message | Failure message ->
       (* The payload is a string by construction: this is the boundary parse
          [classify_string] exists for. *)
       classify_string message
     | _ -> Other (Printexc.to_string exn))

let to_short_tag = function
  | Fd_exhaustion -> "fd_exhaustion"
  | Disk_exhaustion -> "disk_exhaustion"
  | Permission_denied -> "permission_denied"
  | Connection_refused -> "connection_refused"
  | Timeout -> "timeout"
  | Other _ -> "other"
