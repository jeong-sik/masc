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
    empty profile the server owns. *)

type automation = { driver : string; binary : string option }
type stagehand = { chrome : string; extension : string; profile : string option }
type t = { automation : automation option; stagehand : stagehand option }

(** Neither backend configured. *)
val none : t

val parse : Otoml.t -> (t, string) result
