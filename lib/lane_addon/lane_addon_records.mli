(** What an installation may read from the operator's records (RFC
    operator-quiz §4.5, K3). The grants are [binding.records]; the host reads
    that key itself, as it reads [binding.sources].

    Only an operator-owned TOML declaration may hold grants. A manual Attach or
    a Keeper-owned installation that names [records] is refused. *)

type grant =
  | Board of { source_id : string; visibilities : Board_types.visibility list }
      (** Posts and comments in exactly these visibilities. [direct] posts are
          read only when named. *)
  | Repository of { source_id : string; repository_id : string; paths : string list }
      (** First-parent commits of a registered repository's default branch,
          and files under [paths]. A path that ends in [/] covers a directory;
          any other path names one file. *)

val source_id : grant -> string

val grants : operator_owned:bool -> Yojson.Safe.t -> (grant list, string) result
(** The grants of a binding object. No [records] key is no grant.
    [operator_owned] says whether the binding belongs to an operator-owned
    TOML declaration. Every
    grant is checked: a closed kind, a unique non-blank [source_id], a
    non-empty [visibilities] for [board], and relative [paths] with no [..]
    for [repository]. Any other key is refused. *)

val covers : paths:string list -> string -> bool
(** Whether a repository-relative file path falls under a grant's [paths]. *)
