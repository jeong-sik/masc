(** Whether a workspace that has a browser lane host installed also has the
    browser Add-on that host's polls are answered by.

    Since #44295 a native browser host's polls go only to an attached browser
    Add-on. A server started on a workspace with an installed host and no saved
    declaration for that Add-on answers every poll with HTTP 503, and so does
    one with two enabled browser declarations, since it cannot choose between
    them. This reads files only, the way the deployment preflight does: no
    server runs and no worker starts. The declaration is the operator's to
    save, so this reports and never writes one. *)

type verdict =
  | Not_required
      (** No complete lane host installation is under the workspace: no
          launcher, or one whose declaration is missing, unreadable or written
          for other launcher contents. Such a host is not one that polls. *)
  | Declared of { id : string }
      (** Exactly one enabled declaration names a package whose service is the
          browser. *)
  | Ambiguous of { ids : string list }
      (** More than one enabled declaration names a browser package. *)
  | Missing of
      { host_directory : string
      ; directory : string
      ; unloaded : Lane_addon_config.issue list
      ; complete : bool
      }
      (** A host is installed and no enabled browser declaration loaded from
          [directory], the one the server reads. [unloaded] lists the
          declarations that did not load, since one of them may be the
          browser's. [complete] is false when the directory could not be read
          completely. *)

val judge : base_path:string -> verdict

(** [Ok] is the one line a deployment that may proceed reports. [Error] is the
    operator-facing refusal for a verdict it must not proceed on. *)
val report : verdict -> (string, string) result
