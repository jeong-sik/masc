(** The geckodriver process one MASC server owns for its automation lane.

    A WebDriver remote end holds one session. A driver started outside the
    server outlived the server that opened its session without closing it, and
    every later server was refused with "Session is already started" while its
    own record said no session was open. The server now starts its own driver
    on a free loopback port, writes down that it did, and stops it on release.
    A server that died before releasing leaves that record, and the next server
    on the same workspace stops the recorded driver before starting its own. *)

type owner = { pid : int; driver : string }
(** [pid] leads the driver's process group, so stopping the group also stops
    the browser the driver launched, unless that browser relaunched itself
    (see {!browsers_using_profile_root}). [driver] is the executable path
    started. *)

val owner_record_path : masc_root:string -> string
val owner_to_string : owner -> string
val owner_of_string : string -> (owner, string) result

val profile_root : masc_root:string -> string
(** The directory geckodriver creates every automation browser profile in.
    It belongs to this workspace's server, so a process using a profile under
    it is this server's browser. *)

val argv : driver:string -> port:int -> profile_root:string -> string list
(** Loopback only. [--websocket-port 0] lets Firefox pick the WebDriver BiDi
    port, so drivers of two workspaces never meet on geckodriver's default
    9222; the session capabilities report the port it picked.
    [--profile-root] puts each session's profile under [profile_root]. *)

val browsers_using_profile_root : profile_root:string -> process_table:string -> int list
(** [process_table] is [ps -axo pid=,command=] output. Returns every pid whose
    command carries [-profile <profile_root>/...]: the browser and, because
    Zen passes them the same argument, its content processes.

    On 2026-09-15 a Zen the driver launched crashed and relaunched itself with
    [MOZ_LAUNCHED_CHILD=1]: no parent, its own process group, the same
    [-profile] argument. Stopping the driver's group did not reach it, and it
    kept BiDi port 9222. The profile path is what that relaunch keeps, so it
    is what ownership is decided by. *)

type leftover = Stop_recorded_driver of int | Not_the_recorded_driver

val leftover : owner -> command:string option -> leftover
(** [command] is the command line the process table shows for [owner.pid]
    now, [None] when no such process exists. Only a process whose executable
    is the recorded driver is stopped: a pid the system handed to another
    program since then is left alone. *)
