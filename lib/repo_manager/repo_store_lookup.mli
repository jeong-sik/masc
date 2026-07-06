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
  val find_url_by_id_result :
    base_path:string -> repository_id -> (string option, string) result

  val find_url_by_id : base_path:string -> repository_id -> string option

  val find_repo_by_path_prefix_result :
    base_path:string -> string -> ((repository * string) option, string) result

  val find_repo_by_path_prefix :
    base_path:string -> string -> (repository * string) option
end
