(** The [\[browser\]] table of [runtime.toml]. No process is started and no
    file is read while parsing.

    [automation]: [driver] is the geckodriver executable the attached browser
    Add-on owns; [binary] is the browser geckodriver is asked to
    launch. An explicit binary is never replaced by an implicitly discovered
    Firefox executable.

    [stagehand] ([\[browser.stagehand\]], RFC-browser-lane-stagehand §3.6):
    [chrome] is the Chromium-family executable, [extension] the unpacked
    Stagehand extension directory, and [profile] an operator-owned profile
    directory kept between sessions; without it each session starts from an
    empty profile the Add-on owns.

    [live_bidi] ([\[browser.live.bidi\]], RFC-browser-keeper-firefox §3.1):
    the Keeper Firefox the browser Add-on starts with its own BiDi peer. [firefox]
    is the Firefox executable, [profile] the operator-owned profile it opens,
    which keeps the operator's logins, and [port] its
    [--remote-debugging-port]. Both paths are required; [port] defaults to
    {!default_live_bidi_port}.

    [live_ego] ([\[browser.live.ego\]], RFC-browser-live-ego §7): the ego
    lite task space the browser Add-on serves as a live connection.
    [command] is the absolute path of [ego-browser]; [space] is a name to
    create/resume, or an existing numeric Space ID to resume exactly.
    Both are required. Neither grants takeover or claim authority. *)

type automation = { driver : string; binary : string option }
[@@deriving show, eq]
type stagehand = { chrome : string; extension : string; profile : string option }
[@@deriving show, eq]
type live_bidi = { firefox : string; profile : string; port : int }
[@@deriving show, eq]
type ego_space = Named_space of string | Existing_space of int
[@@deriving show, eq]
val validate_ego_space : ego_space -> (unit, string) result
(** Nonblank names and nonnegative JavaScript-safe IDs only. A numeric-looking
    string remains a name; only a TOML integer selects an existing Space. *)
type live_ego = { command : string; space : ego_space }
[@@deriving show, eq]
type t = {
  automation : automation option;
  stagehand : stagehand option;
  live_bidi : live_bidi option;
  live_ego : live_ego option;
}
[@@deriving show, eq]

(** How each source starts, never whether it runs: a source runs while its
    Lane Add-on declaration is switched on. The canonical automation table is
    [\[browser.automation\]]; root [geckodriver]/[binary] is also read, and a
    file using both locations is refused. *)

(** The port the attach steps have always used (docs/design/browser-bidi-live-host.md). *)
val default_live_bidi_port : int

(** No backend configured. *)
val none : t

val parse : Otoml.t -> (t, string) result

(** {!parse} of the runtime.toml at [path], for a reader with no runtime
    configuration loaded, such as [masc doctor]. [Error] says why the file
    cannot be read or its tables do not parse. *)
val of_file : string -> (t, string) result

(** A source that starts from a runtime.toml table, with what that table
    parses to. External hosts need none. *)
type _ source =
  | Automation : automation source
  | Stagehand : stagehand source
  | Live_bidi : live_bidi source
  | Live_ego : live_ego source

(** Where runtime.toml writes [source]'s table. *)
val source_path : _ source -> string

(** [source]'s table as parsed, [None] when runtime.toml has none. *)
val source_table : 'a source -> t -> 'a option
