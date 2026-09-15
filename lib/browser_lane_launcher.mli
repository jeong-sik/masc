(** Where an installed browser-lane host sends its polls, beside the port the
    workspace connection names and the port this process serves the lane on.
    It reads files only: it never says that a host process is running or
    connected. [masc doctor] and the browser tools answer from this one
    observation and its {!verdict}. *)

(** What install-host.sh left under [<base-path>/.masc/browser-lane/host]:
    the [launch] script Firefox runs and the [launch.json] declaration beside
    it that says where that host takes its server address from. *)
type launcher =
  | Not_installed
  | Undeclared
      (** [launch] exists with no declaration beside it, so this observation
          cannot say where that host polls. *)
  | Unreadable  (** The declaration exists but does not decode. *)
  | Follows_workspace
      (** The host reads the workspace connection port, and moves to a new
          port only once its current server stops answering the lane and the
          new one answers it. *)

type t =
  { base_path : string
  ; launcher : launcher
  ; workspace_port : (int, Workspace_connection.error) result
        (** The port connection.toml names, or the default when it names none. *)
  ; serving_port : int option
        (** The port this process serves the browser-lane routes on; [None]
            in a process that serves none, such as [masc doctor]. *)
  }

val observe : base_path:string -> serving_port:int option -> t

type verdict =
  | Absent  (** No launcher is installed. *)
  | Aligned
      (** The host takes the workspace port, and that port is the one this
          process serves on, or no server runs in this process to compare. *)
  | Misconfigured
      (** The host cannot be shown to reach this server: an undeclared or
          unreadable launcher, a workspace port that cannot be read, or a
          workspace port that differs from the serving port. *)

val verdict : t -> verdict

(** One operator sentence naming the cause and the change that resolves it. *)
val message : t -> string

(** [launcher], [workspace_port], [workspace_port_error], [serving_port],
    [verdict] and [message], for a tool result a Keeper reads. *)
val to_json : t -> Yojson.Safe.t
