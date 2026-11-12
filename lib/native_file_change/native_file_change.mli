(** Kernel file-change hints for one immutable set of paths.

    Linux uses inotify; macOS uses a kqueue vnode watch per target. This is a
    current-state observation source, not an event count or durable journal.
    It runs no timer, child process or blocking native wait. *)

type kind = Directory | File
type target = { path : string; kind : kind; device : int; inode : int }

type operation = Create | Register of string | Drain
type error =
  | Unsupported_platform
  | System_error of { operation : operation; error : Unix.error }
  | Ambiguous_watch_identity
  | Target_changed
  | Closed

type loss = Overflow | Target_retired | Unknown_watch
type change = Changed of target list | Coverage_lost of loss
type t

val create : sw:Eio.Switch.t -> targets:target list -> (t, error) result
(** Register the complete set or release every resource on failure. The set
    is sealed: no watches can be added, removed or rebound in this instance.
    Changing topology requires a new instance, armed before retiring the old.
    Registration checks the opened inode against [device]/[inode]. Linux
    registers via that opened descriptor, so a pathname replacement during
    setup cannot silently bind a different inode between two inventory scans.

    Inotify descriptors are mapped only within their original sealed instance.
    A duplicate watch descriptor during registration is rejected as ambiguous;
    the caller should deduplicate inode aliases in its inventory. A retired or
    unknown watch loses the whole instance's coverage. Queued IN_IGNORED can
    therefore never be interpreted using a newly rebound token/path mapping. *)

val drain : t -> (change option, error) result
(** Drain one available native batch without waiting. Kernel aggregation and
    loss are preserved; the caller must not infer a number of writes. *)

val await : t -> (change, error) result
(** Await FD readiness using Eio, then drain nonblocking. Spurious readiness is
    retried without a scan/timer. Cancellation propagates unchanged. *)

val close : t -> unit
(** Idempotent. One owning fiber drives drain/await/close; it must finish or
    cancel its wait before closing. Normal switch release cancels its owning
    daemon before releasing the descriptor and all watched file handles. *)

val error_to_string : error -> string
(** Diagnostics omit watched paths; source paths can contain private data. *)
