(** What is said of a workspace's BiDi browser host: the host's own record,
    beside the launcher it is started with and the connections this process's
    server lists. [masc doctor], the dashboard's onboarding check, the
    connection list the TUI reads and the browser tools answer from this one
    observation. *)

type observation =
  { lane : Browser_lane_launcher.t
        (** The launcher, and the server with the connections it listed. *)
  ; record : Browser_bidi_host_record.state
        (** What the host's record and its lock say. It is read from disk, so
            it is known without a server. *)
  }

(** Reads the record and the launcher, then asks this process's server.
    Reading can let other fibers run, so the server is asked last: a host
    that attached during the reads is in the list the observation holds. *)
val observe : base_path:string -> observation

(** The lane's connections an answer lists beside what it says of the host:
    the list the observation was made from, so the two say of one list. A
    process that bound no listener was not asked for one, and its lane is
    listed by this call. *)
val listed_clients : observation -> Browser_lane.client_info list

(** {!listed_clients} without the BiDi connection of a host the record says
    no longer runs. The server lists that connection until its lease ends,
    and nothing polls it, so a command sent there is never taken. *)
val live_clients : observation -> Browser_lane.client_info list

(** What the record, the lock and the observed server say together. *)
type verdict =
  | Host_absent
      (** No host has run and no browser lane is installed: there is nothing
          to say of one. *)
  | Host_serving
      (** A host runs and the observed server lists its client as a BiDi
          connection, so hover and drag are served there. *)
  | Host_unverified
      (** A host runs and that is all that is known: it is still connecting,
          no server is observed here, or the observed one does not list the
          client its record names. *)
  | Host_not_running
      (** None runs: the last one ended or died, or none has run where a
          lane is installed. *)
  | Host_unreadable  (** The record or its lock cannot be read. *)

val verdict : observation -> verdict

(** Whether a host runs and is attached, when and why the last one ended,
    and what the operator does next. That step follows what became of the
    last host's session:
    - ended, or never given: the Firefox takes the next host as it is; a
      host that never got one needs a Firefox that answers at its address
      first;
    - not confirmed ended, or the connection gone before it could be ended:
      the Firefox is restarted before the next host;
    - refused, or a host that left no reason: the next host is run first,
      and the Firefox is restarted when that host is refused a session.
    The command names the address the last host was given. With a server
    observed it also says whether that server lists a running host's client,
    when it still lists the connection of a host that no longer runs, and
    when it lists a BiDi connection that is not the host the record names.

    A path, an address and the reason for ending come from files and from
    the host. In a command the operator runs, a path and an address are
    written as one shell word. Elsewhere in the paragraph they are written
    as read. The reason is set in quotes, with a quote in it marked. *)
val message : observation -> string

(** The launcher a host is started with, as the observation found it. *)
type launcher_standing =
  | Launcher_installed
  | Launcher_not_installed  (** The browser lane is installed first. *)
  | Launcher_needs_reinstall
      (** A launcher is there and is not as one installation wrote it: the
          lane is installed again before it is run. *)

(** The host's option that names the address it attaches to. The host
    parses it under this name, and every command said here is written
    with it. *)
val bidi_url_flag : string

(** Firefox's option that opens its BiDi address on a port. *)
val firefox_flag : string

(** How a host is started, for a Firefox the operator started with
    [--remote-debugging-port PORT]: where this workspace's launcher is, or
    will be once the lane is installed, and what it is given. *)
type attach = { launcher : string; arguments : string; standing : launcher_standing }

(** What a reader is told of the BiDi host: the state its record and lock
    say, how one is attached, and {!message}. *)
type report =
  { state : Browser_bidi_host_record.state
  ; attach : attach
  ; message : string
  }

val report : observation -> report

(** An object with exactly these fields. [state] ([never_started],
    [running], [ended], [died], [unreadable]) and what it was read from:
    [record] (the host's own record, null when there is none or it cannot be
    read), [lock_held] (true or false where the state turns on it, null
    otherwise and for a lock that could not be asked) and [detail] (why the
    record or the lock cannot be read, null otherwise). Then [attach], an
    object with exactly [launcher], [arguments] and [launcher_state]
    ([installed], [not_installed] or [needs_reinstall]), and [message]. *)
val report_to_json : report -> Yojson.Safe.t

(** Reads what {!report_to_json} wrote. A field more, fewer or twice, in the
    report or in [attach], is another layout and is refused. The state is
    worked out again from [record] and [lock_held] by
    {!Browser_bidi_host_record.state_of} and has to be the one [state]
    names. *)
val report_of_json : Yojson.Safe.t -> (report, string) result

val to_json : observation -> Yojson.Safe.t

(** [state] and [message] alone, for an answer a Keeper passes on to the
    operator: the record itself stays with the readers that show it. *)
val summary_to_json : observation -> Yojson.Safe.t
