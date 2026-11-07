(** A browser source more than one enabled declaration serves, with those
    declarations' ids. *)
type doubled = { source : Browser_lane.Backend.t; ids : string list }

(** Owned sources more than one enabled declaration serves. Ego installations
    select their own Spaces and are checked by actual client/native Space
    identity after connection. Reads files only, the way the deployment
    preflight does: no server runs and no worker starts. *)
val doubled_sources : base_path:string -> doubled list

(** [Ok] when no source is doubled; otherwise the operator-facing refusal
    naming each doubled source and its declarations. *)
val report_doubled : doubled list -> (unit, string) result
