(** Where an installed browser-lane host sends its polls, beside the port the
    workspace connection names and what this process observes of the lane it
    serves. It reads files and, in a serving process, the browser Add-on's
    last published observation through the reader the server installed.
    [masc doctor] and the dashboard's onboarding check answer from this one
    observation and its {!verdict}. *)

(** What a lane installation left under [<base-path>/.masc/browser-lane/host]:
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

(** Why the browser Add-on lists no host for this server. *)
type unlisted =
  | No_browser_addon  (** The workspace declares no browser Add-on. *)
  | Browser_addon_off  (** A browser Add-on is declared and switched off. *)
  | Browser_addon_not_running
      (** One is declared on and the server runs no installation of it. *)
  | Browser_addon_unreadable of string
      (** Its observation, or the declarations, could not be read; why, in
          words any caller may be shown: {!message} and the BiDi host
          paragraph that carries it reach a read-state route. *)

(** Which browser hosts poll this server. Browser hosts register with the
    browser Add-on's worker, not with the server process, so this is what
    the Add-on last published. *)
type polling =
  | Polling of Browser_lane.client_info list
      (** The hosts whose poll lease is current, as the Add-on published them. *)
  | Unlisted of unlisted
  | Not_observed
      (** This serving process has no browser Add-on reader installed, so
          which hosts poll it is not observed. *)

(** What this process observes of the lane it serves. *)
type server =
  | Not_serving
      (** No bound listener is known in this process: [masc doctor], or a
          server before its listener binds. Which port a host should reach
          is not observed here. *)
  | Serving of { port : int; polling : polling }
      (** The port this server's listener bound and which browser hosts poll it. *)

(** The server installs how it reads the browser Add-on, as it installs the
    port it bound ({!Browser_lane.install_serving_port}). [None] removes it. *)
val install_browser_addon_reader : (unit -> polling) option -> unit

(** [Not_serving] while no bound port is installed; the reader is not asked
    then. With a bound port it asks the installed reader, and without one it
    answers [Not_observed]. *)
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
  | Addon_missing
      (** A launcher is installed, no host polls, and the workspace declares
          no browser Add-on, so no host can register with this server. *)
  | Addon_off  (** The same with the browser Add-on declared and switched off. *)
  | Addon_not_running
      (** The same with the browser Add-on declared on and not run by this server. *)
  | Addon_unreadable
      (** A launcher is installed, and this server cannot read whether a host
          polls it. *)
  | Aligned
      (** No host polls, and the declared launcher's host would start on the
          workspace port, which is the port this server bound. *)
  | Unverified
      (** The declared launcher follows a readable workspace port, and no
          server in this process says which port a host should reach, or the
          server installed no browser Add-on reader. *)
  | Misconfigured
      (** No host polls here, and the launcher is undeclared, unreadable or
          declared for other contents, the workspace port cannot be read, or
          the workspace port differs from the port this server bound. *)

val verdict : t -> verdict

(** One operator sentence naming the cause and the change that resolves it. *)
val message : t -> string

(** What the operator is told when the browser Add-on lists no host for this
    server, with what they do about it. {!message} says it for the verdicts
    it decides. *)
val unlisted_message : base_path:string -> unlisted -> string

(** Where this workspace's [launch] script is, or will be once the lane is
    installed. *)
val launcher_path : base_path:string -> string

(** Where this workspace's [launch.json] is, beside {!launcher_path}. *)
val declaration_path : base_path:string -> string

(** The directory holding both, [<base-path>/.masc/browser-lane/host]. *)
val host_directory_path : base_path:string -> string

(** The text of the [launch.json] that goes with a [launch] script of exactly
    these bytes: the one object {!observe} accepts, whose digest ties the
    declaration to that script. The installer writes this and nothing else, so
    the reader and the writer cannot disagree on the fields. *)
val declaration : launcher_script:string -> string

(** What [masc browser-lane-setup] sets up, by {!route_name}: the MASC extension
    Firefox loads, the Firefox MASC starts itself with a BiDi host, or the host
    and its launcher alone. The last connects no browser. It is for a browser
    the operator attaches by hand, and for bringing an installed lane's host up
    to the build that is running. It writes no extension, no manifest and no
    [runtime.toml]. *)
type route = Extension | Bidi | Host

val routes : route list

(** The [--mode] value that names the route. *)
val route_name : route -> string

(** The command that installs the lane for this workspace for a route, as the
    words that follow "the operator runs". *)
val install : route:route -> base_path:string -> string
