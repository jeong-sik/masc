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
  live_enabled : bool;
  automation_enabled : bool;
  stagehand_enabled : bool;
}
[@@deriving show, eq]

(** Activity is independent of backend configuration and installed executors.
    Omitted [enabled] keys preserve current behavior during the accepting
    deployment. The canonical automation table is [\[browser.automation\]].
    That deployment also accepts root [geckodriver]/[binary], but refuses a
    file using both locations. Turning a lane off keeps these paths intact. *)

(** The port the attach steps have always used (docs/design/browser-bidi-live-host.md). *)
val default_live_bidi_port : int

(** No backend configured. *)
val none : t

val parse : Otoml.t -> (t, string) result

(** {!parse} of the runtime.toml at [path], for a reader with no runtime
    configuration loaded, such as [masc doctor]. [Error] says why the file
    cannot be read or its tables do not parse. *)
val of_file : string -> (t, string) result
