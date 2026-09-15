(** Where an installed browser-lane host sends its polls, beside the port the
    workspace connection names. It reads configuration only: it never says
    that a host process is running or connected. [masc doctor] and the
    browser tools answer from this one observation and its {!verdict}. *)

(** The [--server] word of the launcher install-host.sh wrote under
    [<base-path>/.masc/browser-lane/host/launch]. *)
type launcher =
  | Not_installed
  | Unreadable
  | Follows_workspace
      (** No [--server]: the host reads the workspace connection port at
          launch and again after a failed request. *)
  | Pinned of int  (** [--server] fixes this port. *)
  | Unusable_origin
      (** [--server] is not an http origin with a usable port. *)

type t =
  { launcher : launcher
  ; workspace_port : (int, Workspace_connection.error) result
        (** The port connection.toml names, or the default when it names none. *)
  }

val observe : base_path:string -> t

type verdict =
  | Absent  (** No launcher is installed. *)
  | Aligned  (** The launcher reaches the workspace port as configured today. *)
  | Misconfigured
      (** The launcher cannot reach it: unreadable, an unusable or different
          fixed port, or a workspace port that cannot be read. *)

val verdict : t -> verdict

(** One operator sentence naming the cause and the change that resolves it. *)
val message : t -> string

(** [launcher], [launcher_port], [workspace_port], [workspace_port_error],
    [verdict] and [message], for a tool result a Keeper reads. *)
val to_json : t -> Yojson.Safe.t
