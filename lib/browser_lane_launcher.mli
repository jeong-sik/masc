(** Where an installed browser-lane host sends its polls, beside the port the
    workspace connection names and what this process observes of the lane it
    serves. It reads files and this process's lane state only. [masc doctor],
    the dashboard's onboarding check and the browser tools answer from this
    one observation and its {!verdict}. *)

(** What install-host.sh left under [<base-path>/.masc/browser-lane/host]:
    the [launch] script Firefox runs and the [launch.json] declaration the
    same installation wrote beside it.

    [launch.json] is an object with exactly two fields: [destination], whose
    one value is ["workspace_connection"], and [launcher_sha256], the
    lowercase hex SHA-256 of the [launch] bytes. A missing, duplicated or
    unknown field, or any other value, makes it [Unreadable]: a field this
    reader does not know could change what the host does, so it is refused
    rather than ignored. *)
type launcher =
  | Not_installed
  | Undeclared
      (** [launch] exists with no declaration beside it, so this observation
          cannot say where that host polls. *)
  | Unreadable
      (** The declaration or the launcher cannot be read, or the declaration
          is not the object described above. *)
  | Describes_another_launcher
      (** The declaration's [launcher_sha256] is not the digest of the
          [launch] beside it: they were not written by one installation. *)
  | Follows_workspace
      (** The host reads the workspace connection port when it starts. After
          a failed request it reads the port again, stays while its current
          server still answers the lane, and moves only to an address that
          answers. *)

(** What this process observes of the lane it serves. *)
type server =
  | Not_serving
      (** No bound listener is known in this process: [masc doctor], or a
          server before its listener binds. Which port a host should reach
          is not observed here. *)
  | Serving of { port : int; polling : Browser_lane.client_info list }
      (** The port this server's listener bound and the browser hosts whose
          poll lease on it is current. *)

val current_server : unit -> server

type t =
  { base_path : string
  ; launcher : launcher
  ; workspace_port : (int, Workspace_connection.error) result
        (** The port connection.toml names, or the default when it names none. *)
  ; server : server
  ; bidi_host : Browser_bidi_host_record.state
        (** What the BiDi host's own record and its lock say. It is read from
            disk, so it is known without a server. *)
  }

(** Reads the files, then asks [server]. Reading can let other fibers run, so
    the server is asked last: a caller that lists the lane's clients right
    after this returns lists them as of the same moment. *)
val observe : base_path:string -> server:(unit -> server) -> t

type verdict =
  | Absent  (** No launcher is installed and no browser host polls here. *)
  | Connected  (** A browser host polls this server now. *)
  | Aligned
      (** No host polls, and the declared launcher's host would start on the
          workspace port, which is the port this server bound. *)
  | Unverified
      (** The declared launcher follows a readable workspace port, and no
          server in this process says which port a host should reach. *)
  | Misconfigured
      (** No host polls here, and the launcher is undeclared, unreadable or
          declared for other contents, the workspace port cannot be read, or
          the workspace port differs from the port this server bound. *)

val verdict : t -> verdict

(** One operator sentence naming the cause and the change that resolves it. *)
val message : t -> string

(** {1 The BiDi host}

    What the host's own record says, as one paragraph for the operator and
    as a report other programs read. *)

(** Whether the observed server lists the client a running host's record
    names, as a BiDi client: an extension connection under that ID is not
    that host. The record is the host's word and the list is the server's: a
    host the list lacks serves nothing on that server. *)
type bidi_host_poll =
  | Poll_unobserved  (** No server is observed in this process. *)
  | Polls_here
  | Not_listed_here
      (** The host polls another server, has not polled within the lane's
          window, registered under an ID it could not write down, or has not
          reached a server that just started. *)

val bidi_host_poll : t -> Browser_bidi_host_record.entry -> bidi_host_poll

(** What the record, the lock and the observed server say together. *)
type bidi_host_verdict =
  | Bidi_absent
      (** No host has run and no browser lane is installed: there is nothing
          to say of one. *)
  | Bidi_serving
      (** A host runs and the observed server lists its client, so hover and
          drag are served there. *)
  | Bidi_unverified
      (** A host runs and that is all that is known: it is still connecting,
          no server is observed here, or the observed one does not list it. *)
  | Bidi_not_running
      (** None runs: the last one ended or died, or none has run where a
          lane is installed. *)
  | Bidi_unreadable  (** The record or its lock cannot be read. *)

val bidi_host_verdict : t -> bidi_host_verdict

(** Whether a host runs and is attached, when and why the last one ended,
    and what the operator does next. That step follows what became of the
    last host's session: a Firefox that still holds one is restarted first,
    and one that holds none takes the next host as it is. With a server
    observed it also says whether that server lists a running host's
    client. *)
val bidi_host_message : t -> string

(** The launcher a host is started with, as this observation found it. *)
type bidi_launcher =
  | Launcher_installed
  | Launcher_not_installed  (** The browser lane is installed first. *)
  | Launcher_needs_reinstall
      (** A launcher is there and is not as one installation wrote it: the
          lane is installed again before it is run. *)

(** How a host is started, for a Firefox the operator started with
    [--remote-debugging-port PORT]: where this workspace's launcher is, or
    will be once the lane is installed, and what it is given. *)
type bidi_attach = { launcher : string; arguments : string; standing : bidi_launcher }

(** What a reader is told of the BiDi host: the state its record and lock
    say, how one is attached, and {!bidi_host_message}. *)
type bidi_host_report =
  { state : Browser_bidi_host_record.state
  ; attach : bidi_attach
  ; message : string
  }

val bidi_host_report : t -> bidi_host_report

(** [state] ([never_started], [running], [ended], [died], [unreadable]) and
    what it was read from: [record] (the host's own record, null when there
    is none or it cannot be read), [lock_held] (true or false where the
    state turns on it, null otherwise and for a lock that could not be
    asked) and [detail] (why the record or the lock cannot be read, null
    otherwise). Then [attach] ([launcher], [arguments], and [launcher_state]:
    [installed], [not_installed] or [needs_reinstall]) and [message]. *)
val bidi_host_report_to_json : bidi_host_report -> Yojson.Safe.t

(** Reads what {!bidi_host_report_to_json} wrote. The state is worked out
    again from [record] and [lock_held] by {!Browser_bidi_host_record.state_of}
    and has to be the one [state] names. *)
val bidi_host_report_of_json : Yojson.Safe.t -> (bidi_host_report, string) result

val bidi_host_to_json : t -> Yojson.Safe.t

(** [state] and [message] alone, for an answer a Keeper passes on to the
    operator: the record itself stays with the readers that show it. *)
val bidi_host_summary_to_json : t -> Yojson.Safe.t

(** [launcher], [workspace_port], [workspace_port_error], [serving_port],
    [polling_hosts], [verdict] and [message], for a tool result a Keeper
    reads. The two server fields are null when no server is observed. *)
val to_json : t -> Yojson.Safe.t
