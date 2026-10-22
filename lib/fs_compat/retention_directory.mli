(** Descriptor-owned retention scopes. The raw default runner blocks;
    Fs_compat supplies a runner that offloads each operation while callbacks
    stay on the caller's fiber (and can retain its Eio store mutex).
    No directory component or file target is followed through a symbolic link. *)
type t
(** Scopes expire and close handles on return, exception and cancellation. A
    close failure after a returned callback propagates as its original I/O
    exception. If callback failure/cancellation and close failure coincide, the
    callback exception is re-raised and the close failure is reported on stderr. *)

type io = { run : 'a. (unit -> 'a) -> 'a }
(** Operation runner, inline by default. The Fs_compat facade runs blocking
    operations on a system thread while callbacks stay on their caller. *)

val with_root : ?io:io -> string -> (t -> 'a) -> 'a option
(** Bind an absolute physical root by opening every component from [/]
    with no-follow [openat]. Missing roots return [None]; links and other
    non-directories are refused. No [realpath] preflight grants authority.
    The descriptor, rather than its subsequently replaceable spelling,
    owns the scope. This is per-pass admission, not a boot identity lease. *)

val with_child : t -> string -> (t -> 'a) -> 'a option
(** Bind one immediate directory. Missing/non-directory/link entries are
    skipped. Other errors propagate. The handle expires after its callback;
    using an escaped handle raises [Invalid_argument], never a reused fd. *)

val names : t -> string list
val fold_children : t -> init:'a -> f:('a -> string -> t -> 'a) -> 'a
val descend : t -> string list -> (t -> int) -> int

val remove_regular_file : ?older_than:float -> t -> string -> bool
(** Inspect without following links and unlink relative to the held parent.
    [true] counts an actual unlink. Missing/non-regular entries are skipped.
    Leaf inspection/removal [Unix_error] is reported with its diagnostic path
    and errno, then skipped without counting; other entries/stores continue.
    Directory opening/enumeration errors still propagate. POSIX has no atomic inode/mtime-conditional
    unlink: a concurrent leaf replacement can remove that replacement entry
    inside the owned parent, but never a symlink's target. *)

val unlink_entry : t -> string -> bool
(** Unlink one immediate non-directory entry relative to the held parent,
    without following a symbolic link. [true] acknowledges a successful unlink;
    [false] means [ENOENT]. Other errors propagate, including directories.
    No age/type eligibility is inferred. No atomic inode-conditional unlink or
    fsync durability is claimed. *)

val remove_empty_child_checked : t -> string -> bool
(** Checked [unlinkat(AT_REMOVEDIR)] relative to the held parent. [true]
    acknowledges an actual removal; [false] means [ENOENT]; all other errors
    propagate. A replacement link is never followed. *)

val remove_empty_child : t -> string -> unit
(** Best-effort [unlinkat(AT_REMOVEDIR)]; never follows a replacement link. *)
