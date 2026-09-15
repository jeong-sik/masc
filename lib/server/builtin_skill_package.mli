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

(** What reconciliation did with a package this binary ships. *)
type bundled_verdict =
  | Install_missing
      (** No package directory existed; the bundled package and its receipt were published. *)
  | Up_to_date
      (** The receipt matches the installed tree and the tree equals this release. *)
  | Adopt_identical
      (** The installed tree already equals this release byte for byte, but its
          receipt was absent or described another tree. Only the receipt was written. *)
  | Replace_recorded of { backup : string }
      (** The receipt matches the installed tree and this release differs. The
          complete previous tree is kept at [backup]. *)
  | Keep_modified of { revision : string }
      (** The tree changed since its receipt was written and differs from this release. *)
  | Keep_untracked_different of { revision : string }
      (** No receipt, and the tree differs from this release. It may be the
          operator's own version, so it is not replaced. *)
  | Keep_uninspectable of { reason : string }
      (** The tree or receipt is not an owned regular tree (links, special
          files, unreadable directories). Nothing was changed. *)

(** What reconciliation did with a receipt whose package this binary no longer ships. *)
type retired_verdict =
  | Retire_recorded of { backup : string option }
      (** The receipt matched the installed tree: the tree was moved to [backup]
          and the receipt removed. [None]: the package directory was already
          gone, so only the receipt was removed. *)
  | Keep_retired_modified of { revision : string }
      (** The tree changed since installation. Tree and receipt are kept. *)
  | Keep_retired_uninspectable of { reason : string }

type error =
  | Invalid_path of string
  | Revision_conflict of inspection
  | Bundled_revision_conflict of { actual_revision : string }
  | Io_error of string
  | Published_but_unrecorded of { backup : string option; reason : string }
  | Exported_but_unsynced of { destination : string; reason : string }
  | Retired_but_unrecorded of { backup : string; reason : string }

type report =
  | Bundled of { name : string; result : (bundled_verdict, error) result }
  | Retired of { name : string; result : (retired_verdict, error) result }

val inspect : base_path:string -> package -> (inspection, error) result
val export : destination:string -> package -> (unit, error) result
(** Write the complete bundled package to a new directory for a normal diff.
    Never replace an existing destination. *)

val reconcile : base_path:string -> package list -> (report list, error) result
(** Bring [.masc/skills] in line with [packages], the complete set this binary
    ships. One [Bundled] report per package, in order, then one [Retired]
    report per installation receipt whose name is not in [packages].

    A tree is replaced or retired only when its receipt matches it. A tree
    without a receipt is never removed: MASC cannot tell a former builtin from
    the operator's own Skill. A package failure is reported in its own report
    and does not stop the others. [Error] means no package was examined
    (unusable deployment root, lock or receipt directory).

    This is a synchronous installer operation. Callers must serialize operator
    file editing with installation. The advisory lock serializes installers;
    it is not a lock on arbitrary external editors. Refresh a running Skill
    catalog after installation before starting a new instruction invocation. *)

type replacement = Replaced of { backup : string } | Already_current

val replace_reviewed :
  base_path:string ->
  installed_revision:string ->
  bundled_revision:string ->
  package ->
  (replacement, error) result
(** Replace an installed package after the operator reviewed both complete
    revisions, whatever its receipt says. Either revision having changed since
    review rejects the replacement. The old package is retained outside the
    Skill source. Publication exchanges directories atomically; unsupported
    filesystems return an error with the original package intact. *)

val error_message : error -> string
val report_to_string : report -> string
(** One line naming the package, what happened, and the next step when the
    operator has one. *)

module For_testing : sig
  val ensure_directory : sync_parent:(string -> unit) -> string -> (unit, error) result
  (** Observe or fail parent sync after actual directory creation. *)
  val export : sync_parent:(string -> unit) -> destination:string -> package -> (unit, error) result
  (** Inject a parent sync failure after real no-replace publication. *)
end
