(** Automation configuration for the Gecko remote end. No process is started
    and no file is read while parsing. An explicit binary is never replaced by
    an implicitly discovered Firefox executable. *)
type t = Disabled | Webdriver of { endpoint : string; binary : string option }
val parse : Otoml.t -> (t, string) result
