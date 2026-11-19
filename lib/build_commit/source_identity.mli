(** The source a binary was built from (RFC host-and-shim-share-one-build-identity).

    The server and the exec shim both link this module, and both read their
    identity from the one declaration [lib/build_commit/probe-commit.sh]
    generates. The server runs a shim only when the two are equal: the same
    source speaks the same relay and behaves the same, so no protocol number
    has to be kept in step by hand (#52968: a relay-2 server ran a relay-1
    shim because both installers fetched the shim by release version).

    A declaration is one string literal,
    [MASC_SOURCE_IDENTITY=<commit>/clean;] or
    [MASC_SOURCE_IDENTITY=<commit>/modified:<digest>;], so it sits verbatim in
    the binary's bytes and a host that cannot run a Linux shim reads it with
    {!scan}. *)

type state =
  | Clean  (** the working tree had no change against the commit *)
  | Modified of { digest : string }
      (** the git object id of the working tree's change set: the tracked
          diff, untracked regular files and their object ids, untracked
          symlinks and their link targets, and untracked nested repositories *)

type t =
  { commit : string  (** a full lowercase git object name *)
  ; state : state
  }

val current : t option
(** This binary's identity. [None] when its build knew no commit, or a commit
    without a source state (an unknown state is not [Clean]). A server
    without an identity runs no shim. *)

val equal : t -> t -> bool

val to_string : t -> string
(** [<commit>/clean] or [<commit>/modified:<digest>]: the declaration body,
    and the value the guest agent's hello carries. *)

val of_string : string -> t option
(** The inverse of {!to_string}. Anything else, including upper-case hex or
    an object name of another length than 40 or 64, is [None]. *)

val declaration : t -> string
(** The whole declaration, prefix and terminator included, as the generated
    module spells it. Tests write it into fixture shims. *)

type scan =
  | Declared of t  (** exactly one distinct declaration *)
  | Undeclared
      (** none: a shim built before identities, or by a build that knew none *)
  | Several of t list
      (** distinct declarations, in the order the bytes hold them *)

val scan : string -> scan
(** Every whole declaration in a binary's bytes. A prefix that is not
    followed by a body of the grammar above and [;] within the longest body
    length is not a declaration. Never raises. *)
