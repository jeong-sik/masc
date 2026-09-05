(** What `masc` with no subcommand does.

    The front door is the terminal: on a TTY the bare name opens the fleet TUI,
    which starts this same binary as its server when nothing answers the port.
    Everywhere else — a pipe, a unit file, a container, a CI step — it is the
    server it has always been, and `masc start` says so explicitly.

    The decision is pure over its inputs so it runs under a test without a TTY,
    a PATH, or an installed TUI (the pattern {!Masc_tui_server_lifecycle} uses
    for the other direction). The caller supplies the terminal answer and the
    filesystem probe; this module supplies the rule. *)

type t =
  | Serve  (** run the MCP server in this process *)
  | Open_tui of { binary : string; argv : string list }
      (** hand the process over to [binary] with exactly [argv] *)

val tui_binary_name : string
(** ["masc-tui"] — the installed name. A source checkout builds
    [masc_tui.exe] instead, so a dev tree keeps the server it had. *)

val discover_tui :
  executable_name:string ->
  path_env:string option ->
  is_executable:(string -> bool) ->
  string option
(** The TUI beside [executable_name] first — the layout install.sh creates —
    then the first hit walking [path_env]. Empty PATH entries are skipped
    rather than probed as the current directory. *)

val tui_argv : binary:string -> port:int -> base_path:string option -> string list
(** argv for the handover, [binary] included as argv[0]. The TUI takes no
    [--host], which is why {!decide} refuses a non-default one. *)

val decide :
  interactive:bool ->
  host:string ->
  default_host:string ->
  deployment_flags_present:bool ->
  port:int ->
  base_path:string option ->
  executable_name:string ->
  path_env:string option ->
  is_executable:(string -> bool) ->
  t
(** [Serve] unless every condition holds: [interactive], [host] equal to
    [default_host] (a bound address other than the default is a deployment
    asking for a server, and the TUI carries no [--host] to hand it), no
    [deployment_flags_present] (build provenance and the store-quarantine
    override are passed by the deploy path and nothing else), and a TUI found.
    Any single failure keeps the server, so the bare invocation service
    managers already rely on cannot change under them. *)
