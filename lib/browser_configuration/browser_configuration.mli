(** The [\[browser\]] table of [runtime.toml]. No process is started and no
    file is read while parsing.

    [automation]: [driver] is the geckodriver executable the MASC server starts
    and stops for itself; [binary] is the browser geckodriver is asked to
    launch. An explicit binary is never replaced by an implicitly discovered
    Firefox executable.

    [stagehand] ([\[browser.stagehand\]], RFC-browser-lane-stagehand §3.6):
    [chrome] is the Chromium-family executable, [extension] the unpacked
    Stagehand extension directory, and [profile] an operator-owned profile
    directory kept between sessions; without it each session starts from an
    empty profile the server owns.

    [live_bidi] ([\[browser.live.bidi\]], RFC-browser-keeper-firefox §3.1):
    the Keeper Firefox the MASC server starts with its BiDi host. [firefox]
    is the Firefox executable, [profile] the operator-owned profile it opens,
    which keeps the operator's logins, and [port] its
    [--remote-debugging-port]. Both paths are required; [port] defaults to
    {!default_live_bidi_port}. *)

type automation = { driver : string; binary : string option }
[@@deriving show, eq]
type stagehand = { chrome : string; extension : string; profile : string option }
[@@deriving show, eq]
type live_bidi = { firefox : string; profile : string; port : int }
[@@deriving show, eq]
type t = {
  automation : automation option;
  stagehand : stagehand option;
  live_bidi : live_bidi option;
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
