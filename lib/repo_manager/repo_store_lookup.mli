(** Repository lookup helpers factored out of [Repo_store]. *)

open Repo_manager_types

module type Store = sig
  val load_all : base_path:string -> (repository list, string) result
  val local_path : base_path:string -> repository -> string
end

val strip_trailing_slash : string -> string
val is_path_prefix : prefix:string -> string -> bool
val rel_under_path : prefix:string -> string -> string

val longest_local_path :
  ('repo * string * 'rel) list -> ('repo * string * 'rel) option

module Make (Store : Store) : sig
  val find_url_by_id : base_path:string -> repository_id -> string option

  val find_url_by_identity : base_path:string -> string -> string option
  (** [find_url_by_identity ~base_path token] resolves a repository URL by a
      unique registered id, name, or explicit alias. Ambiguous or missing
      tokens return [None]. *)

  val find_repo_by_path_prefix :
    base_path:string -> string -> (repository * string) option
end
