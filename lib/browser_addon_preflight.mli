(** Whether a workspace that has a browser lane host installed also has the
    browser Add-on that host's polls are answered by.

    Since #44295 a native browser host's polls go only to an attached browser
    Add-on. A server started on a workspace with an installed host and no saved
    declaration for that Add-on answers every poll with HTTP 503. This reads
    files only, the way the deployment preflight does: no server runs and no
    worker starts. The declaration is the operator's to save, so this reports
    and never writes one. *)

type verdict =
  | Not_required
      (** No lane host is installed under the workspace, so no host polls. *)
  | Declared of { id : string }
      (** An enabled declaration names a package whose service is the browser. *)
  | Missing of
      { host_directory : string
      ; directory : string
      ; unloaded : Lane_addon_config.issue list
      ; complete : bool
      }
      (** A host is installed and no enabled browser declaration loaded from
          [directory]. [unloaded] lists the declarations that did not load,
          since one of them may be the browser's. [complete] is false when the
          directory could not be read completely. *)
  | Config_root_invalid of string
      (** The directory that holds declarations cannot be named: the
          environment's config root is invalid. *)

val judge : base_path:string -> verdict

(** [Ok] is the one line a deployment that may proceed reports. [Error] is the
    operator-facing refusal for a verdict it must not proceed on. *)
val report : verdict -> (string, string) result
