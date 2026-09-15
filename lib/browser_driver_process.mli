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
    the browser the driver launched. [driver] is the executable path started. *)

val owner_record_path : masc_root:string -> string
val owner_to_string : owner -> string
val owner_of_string : string -> (owner, string) result

val argv : driver:string -> port:int -> string list
(** Loopback only. [--websocket-port 0] lets Firefox pick the WebDriver BiDi
    port, so drivers of two workspaces never meet on geckodriver's default
    9222; the session capabilities report the port it picked. *)

type leftover = Stop_recorded_driver of int | Not_the_recorded_driver

val leftover : owner -> command:string option -> leftover
(** [command] is the command line the process table shows for [owner.pid]
    now, [None] when no such process exists. Only a process whose executable
    is the recorded driver is stopped: a pid the system handed to another
    program since then is left alone. *)
