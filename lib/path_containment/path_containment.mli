(** Filesystem-aware containment for mutation guards. *)

type t =
  | Inside
      (** [path] resolves to [root] itself or to something under it. *)
  | Outside  (** [path] resolves somewhere [root] does not contain. *)
  | Undecidable of string
      (** The destination could not be resolved safely. Mutation guards treat
          this result as a breach. *)

val home_guard_bypass_enabled : string option -> bool
(** [home_guard_bypass_enabled raw] accepts only the exact configured values
    ["1"] and ["true"]. *)

val classify : root:string -> path:string -> t
(** [classify ~root ~path] resolves pathname components in kernel order,
    including symbolic links followed by later [..] components, then compares
    the resolved components.

    A missing ordinary component is retained because mutation targets commonly
    do not exist yet. A symbolic link is resolved even when its target is
    missing. Resolution errors other than a missing ordinary component, and
    symbolic-link cycles, produce {!Undecidable}. Empty strings are
    {!Undecidable}; leading and trailing spaces are valid pathname bytes. *)
