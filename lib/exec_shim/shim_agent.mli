(** The [masc-exec-shim --serve] guest agent (RFC
    microvm-guest-agent-over-socket).

    The first process of an Apple container Keeper VM. It listens on a unix
    socket the VM publishes to the host with [container run --publish-socket]
    and runs one shim request per connection, so a request no longer needs a
    [container exec -i] of its own.

    {!start} runs as root: it makes the socket's directory (root's, mode
    0700), binds and listens, re-mounts [/] read-only, and drops to the
    Keeper's uid and gid with [no_new_privs] set and dumpable cleared. A step
    that fails stops the agent; it never serves with a step undone.

    {!serve} accepts connections and forks one relay for each. {!relay}
    writes a hello, reads one request-kind byte, and runs the shim at the path
    the agent was started from. Bytes from the connection go to the shim's
    stdin; the shim's stdout and stderr go back as chunks as they arrive, then
    one exit chunk. *)

type owner =
  { uid : int
  ; gid : int
  }

val parse_owner : string -> (owner, string) result
(** ["UID:GID"], two decimal numbers. Refuses anything else, and refuses uid
    0 and gid 0: the agent exists to stop serving as root. *)

type start_error =
  | Not_root of { euid : int }
  | Socket_path_relative of string
  | Socket_directory_failed of { directory : string; detail : string }
    (** the directory exists already or could not be made root's 0700 *)
  | Socket_directory_off_root of { directory : string }
    (** the directory sits on another filesystem than [/]; the
        [--publish-socket] relay reaches only sockets on the container's
        root filesystem (RFC section 4.2) *)
  | Listen_failed of { socket : string; detail : string }
  | Remount_failed of string
  | Drop_failed of string

val start_error_to_string : start_error -> string

val start : socket:string -> owner:owner -> (Unix.file_descr, start_error) result
(** The listening socket, close-on-exec, once every step has held. Refuses
    with [Not_root] before touching anything when the effective uid is not 0. *)

val mark_inherited_descriptors_close_on_exec : unit -> unit
(** Marks every descriptor above 2 close-on-exec, so nothing the VM runtime
    left open in the first process reaches a relay's shim or payload.
    {!main} does it first. Raises [Unix.Unix_error]. *)

val hello : unit -> Exec_ssh_protocol.Relay.hello
(** Read from the kernel when called: whether [/] is mounted read-only, the
    effective uid and gid, and [no_new_privs]. *)

val relay :
  conn:Unix.file_descr ->
  program:string ->
  env:string array ->
  host_signal_number:(int -> int) ->
  unit
(** Serves one connection and returns once the shim child is reaped. Runs
    [program] for a [Run] and [program --probe] for a [Probe], with [env] and
    the caller's working directory.

    A connection that ends before the kind byte, or sends an unknown one,
    gets the hello and nothing else. When the host ends its side, the bytes
    it sent before still reach the shim and then the shim's stdin closes —
    the shim reads that as a cancel. When the host goes away (a failed write
    or a reset), its queued bytes are dropped, the shim's stdin closes, and
    the shim's output is still read to the end and dropped, so the shim never
    blocks on a full pipe. [host_signal_number] turns an OCaml signal code
    into the guest OS number the exit chunk carries.

    SIGPIPE must be ignored ({!main} does it), or a host that goes away kills
    the relay instead of reaching those branches. *)

val serve :
  listener:Unix.file_descr ->
  program:string ->
  host_signal_number:(int -> int) ->
  'a
(** Accepts forever, one forked {!relay} per connection with this process's
    environment. Reaps every child, including orphans re-parented to it as the
    VM's first process. Exits [1] when [accept] fails for a reason other than
    an interrupted or aborted connection. *)

val main :
  host_signal_number:(int -> int) ->
  argv0:string ->
  socket:string ->
  owner:string ->
  'a
(** [masc-exec-shim --serve SOCKET UID:GID]. Ignores SIGPIPE, marks inherited
    descriptors close-on-exec, then {!start} and {!serve}. [argv0] must be
    absolute: it is the shim the relays run, so a shim reinstalled at that
    path serves the next request. Prints the reason and exits [1] when the
    owner, the path or {!start} is refused. *)
