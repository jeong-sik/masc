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
  }

val observe : base_path:string -> server:server -> t

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

(** [launcher], [workspace_port], [workspace_port_error], [serving_port],
    [polling_hosts], [verdict] and [message], for a tool result a Keeper
    reads. The two server fields are null when no server is observed. *)
val to_json : t -> Yojson.Safe.t
