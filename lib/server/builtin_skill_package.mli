(** Whole-package distribution updates. Operator resources, deletions and
    permissions participate in the revision, not just SKILL.md. *)
type package

val make : name:string -> files:(string * string) list -> (package, string) result
val name : package -> string
val bundled_revision : package -> string
(** Complete revision of this immutable binary-embedded package value. *)

type ownership = Recorded | Untracked | Modified
type inspection =
  | Missing
  | Present of { revision : string; bundled_revision : string; ownership : ownership }

type request =
  | Seed_missing
  | Automatic
  | Replace_if_revisions of { installed_revision : string; bundled_revision : string }
type outcome =
  | Installed
  | Already_present
  | Current
  | Preserved of inspection
  | Preserved_uninspectable of { reason : string }
  | Updated of { backup : string }

type error =
  | Invalid_path of string
  | Revision_conflict of inspection
  | Bundled_revision_conflict of { actual_revision : string }
  | Io_error of string
  | Published_but_unrecorded of { backup : string option; reason : string }
  | Exported_but_unsynced of { destination : string; reason : string }

val inspect : base_path:string -> package -> (inspection, error) result
val export : destination:string -> package -> (unit, error) result
(** Write the complete bundled package to a new directory for a normal diff.
    Never replace an existing destination. *)
val install : base_path:string -> request:request -> package -> (outcome, error) result
(** [Automatic] replaces only a tree whose complete revision matches its
    installation receipt. Untracked/modified trees remain untouched, even
    when their SKILL.md happens to equal the new builtin. Explicit replacement
    requires both reviewed complete revisions and retains the old package outside
    the Skill source. Publication exchanges directories atomically; unsupported
    filesystems return an error with the original package intact.

    This is a synchronous installer operation. Callers must serialize operator
    file editing with installation. The advisory lock serializes installers;
    it is not a lock on arbitrary external editors. Refresh a running Skill
    catalog after installation before starting a new instruction invocation. *)

val error_message : error -> string

module For_testing : sig
  val ensure_directory : sync_parent:(string -> unit) -> string -> (unit, error) result
  (** Observe or fail parent sync after actual directory creation. *)
  val export : sync_parent:(string -> unit) -> destination:string -> package -> (unit, error) result
  (** Inject a parent sync failure after real no-replace publication. *)
end
