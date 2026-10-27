(** Whether a workspace that has a browser lane host installed also has the
    browser Add-on that host's polls are answered by.

    Since #44295 a native browser host's polls go only to an attached browser
    Add-on, and its first poll binds to the one that serves external hosts
    ([browser_backend = "external_host"], the [browser-external] package). A server
    started on a workspace with an installed host and no saved declaration for
    such an Add-on answers every poll with HTTP 503, and so does one with two
    of them, since it cannot choose between them. Declarations of a package
    that names another source answer no host and are not counted. This reads
    files only, the way the deployment preflight does: no server runs and no
    worker starts. The declaration is the operator's to save, so this reports
    and never writes one. *)

type verdict =
  | Not_required
      (** No complete lane host installation is under the workspace: no
          launcher, or one whose declaration is missing, unreadable or written
          for other launcher contents. Such a host is not one that polls. *)
  | Declared of { id : string }
      (** Exactly one enabled declaration names a browser package that serves
          external hosts. *)
  | Ambiguous of { ids : string list }
      (** More than one enabled declaration names a browser package that
          serves external hosts. *)
  | Missing of
      { host_directory : string
      ; directory : string
      ; unloaded : Lane_addon_config.issue list
      ; complete : bool
      }
      (** A host is installed and no enabled browser declaration serving
          external hosts loaded from [directory], the one the server reads.
          [unloaded] lists the declarations that did not load, since one of
          them may be the browser's. [complete] is false when the directory
          could not be read completely. *)

val judge : base_path:string -> verdict

(** [Ok] is the one line a deployment that may proceed reports. [Error] is the
    operator-facing refusal for a verdict it must not proceed on. *)
val report : verdict -> (string, string) result

(** A browser source more than one enabled declaration serves, with those
    declarations' ids. *)
type doubled = { source : Browser_lane.Backend.t; ids : string list }

(** Every browser source more than one enabled declaration serves. The host
    uses no such source, whether or not a lane host is installed. Reads files
    only, as {!judge} does. *)
val doubled_sources : base_path:string -> doubled list

(** [Ok] when no source is doubled; otherwise the operator-facing refusal
    naming each doubled source and its declarations. *)
val report_doubled : doubled list -> (unit, string) result
