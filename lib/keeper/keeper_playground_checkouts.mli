(** Discover git checkouts under a keeper's workspace root by measurement.

    The system does not regulate what a keeper puts under its workspace root.
    It observes. A directory is a checkout when it holds a [.git] entry; where
    that directory sits is the keeper's business.

    This replaces three independent scans that each hardcoded a [repos/]
    segment and each disagreed about what counted as a checkout: one accepted
    any directory, one required [.git], one excluded dot-prefixed names. See
    RFC-keeper-workspace-root-only §1.2.

    {1 Traversal}

    Breadth-first from the root, stopping at every checkout found — the
    subtree of a checkout belongs to that checkout, so [_build/.sandbox/.git]
    and [node_modules/*/.git] are never reached. That stop is what bounds the
    walk; there is no depth limit, because a depth limit is the same kind of
    layout rule this module exists to remove (a checkout placed one level too
    deep would silently vanish).

    Symlinks are not followed, so the traversal cannot cycle. *)

type git_link =
  | Git_directory (** [<dir>/.git] is a directory: a primary checkout. *)
  | Git_pointer_file
      (** [<dir>/.git] is a regular file holding a [gitdir:] pointer: a linked
          worktree or a submodule. *)

type checkout =
  { relative_path : string
      (** Path from the workspace root. ["repos/masc"], ["masc"], or ["."]
          when the root is itself a checkout. *)
  ; absolute_path : string  (** Normalized absolute path to the checkout. *)
  ; name : string
      (** Basename of [relative_path]; the root's basename when it is ["."]. *)
  ; git_link : git_link
  }

(** Why a scan returned fewer checkouts than the tree may hold. Truncation is
    not failure: the list is real, just partial. Callers must not present a
    truncated list as complete. *)
type limit =
  | Entry_budget_exhausted of
      { scanned : int
      ; budget : int
      }
  | Checkout_budget_exhausted of { budget : int }
  | Directory_unreadable of
      { relative_path : string
      ; detail : string
      }
      (** One subdirectory could not be read. The checkouts found before it are
          still returned — a single unreadable directory does not blank the
          whole listing. *)

(** A scan that produced no list at all. Distinct from [Complete []], which
    says the root exists and holds no checkout. *)
type scan_error =
  | Root_missing of { root : string }
  | Root_not_directory of
      { root : string
      ; kind : string
      }
  | Root_unreadable of
      { root : string
      ; detail : string
      }

type discovery =
  | Complete of checkout list
  | Partial of
      { found : checkout list
      ; limit : limit
      }

val max_reported_checkouts : int
(** Bounded by downstream cost rather than by the scan: each reported checkout
    costs six bounded git subprocesses in
    {!Keeper_sandbox_control.checkout_json}. Live maximum is 12.

    Exposed because a test builds one checkout past it and because the
    endpoint probe in {!Keeper_sandbox_remote_checkouts} receives it as an
    argument. *)

val max_scanned_entries : int
(** The safety stop on directory entries one discovery walk reads. Exposed
    only so the endpoint probe stops at the same number as the host walk. *)

val discover : root:string -> (discovery, scan_error) result
(** [discover ~root] walks [root] and reports the git checkouts under it,
    sorted by [relative_path].

    Checks [root] itself first: if [<root>/.git] exists, the result is that one
    checkout with [relative_path = "."] and nothing below is scanned. *)

val found : discovery -> checkout list
(** The checkouts in a discovery, whether complete or partial. Use only where
    partiality genuinely does not change the answer. *)

val join : checkout -> suffix:string -> string
(** [join c ~suffix] is the root-relative logical path of [suffix] inside [c].

    Handles the two edges that callers previously got wrong in different ways:
    an empty [suffix] (["repos/masc"], not ["repos/masc/"]) and a root checkout
    (["lib"], not ["./lib"]). *)

type name_resolution =
  | Resolved of checkout
  | Not_found
  | Ambiguous of checkout list

val resolve_by_name : discovery -> name:string -> name_resolution
(** Find a checkout by basename. Two checkouts can share a basename once the
    layout is free (a keeper holding both [repos/masc] and [.masc/repos/masc]),
    so this reports [Ambiguous] rather than picking by sort order. *)

val limit_to_string : limit -> string
val scan_error_to_string : scan_error -> string

val scan_json : (discovery, scan_error) result -> Yojson.Safe.t
(** The wire ["scan"] object. Renders complete, truncated, and failed scans
    through one encoder so that "the root is missing" and "the root holds no
    checkout" stay distinguishable on the wire — today both surface as an
    empty list. *)
