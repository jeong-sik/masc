(** Automation configuration. [driver] is the geckodriver executable the MASC
    server starts and stops for itself; [binary] is the browser geckodriver is
    asked to launch. No process is started and no file is read while parsing.
    An explicit binary is never replaced by an implicitly discovered Firefox
    executable. *)
type t = Disabled | Geckodriver of { driver : string; binary : string option }
val parse : Otoml.t -> (t, string) result
