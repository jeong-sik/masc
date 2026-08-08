(** Path_containment — the single answer to "is this path inside that root?".

    Two guards used to answer it independently by comparing unnormalized
    strings, and they disagreed: a sibling whose name extends the root's shares
    the root's prefix without being inside it, and a relative path, a [..]
    segment, a duplicate separator, or a symlink hides the destination from a
    prefix comparison entirely.

    Deciding needs the filesystem, so the answer is three-valued.  {!Undecidable}
    is not a failure to be smoothed over: a caller that cannot resolve a path
    does not know where the write lands, and every caller here treats it the
    same way it treats {!Inside}. Collapsing it into {!Outside} would turn an
    unreadable path into a permitted one. *)

type t =
  | Inside
      (** [path] resolves to [root] itself or to something under it. *)
  | Outside  (** [path] resolves somewhere [root] does not contain. *)
  | Undecidable of string
      (** The question could not be answered — a relative path with no
          reachable cwd, or a root whose existing prefix does not resolve.
          Carries the reason for the operator-facing message. *)

val classify : root:string -> path:string -> t
(** [classify ~root ~path] decides containment by destination rather than by
    spelling.

    Both arguments are made absolute (against the process cwd), normalized
    lexically ([""] and ["."] dropped, [".."] folded), and then resolved with
    {!Unix.realpath} as far as they exist — the longest existing prefix is
    resolved and the remaining components are appended, because the write
    target usually does not exist yet.  Comparison is by path component, so
    ["/home/runner-cache"] is {!Outside} ["/home/runner"] while
    ["/home/runner"] itself is {!Inside}.

    A root that trims to [""] is {!Undecidable}, not a root that contains
    everything. *)
