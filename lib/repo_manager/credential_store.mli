open Repo_manager_types

val load_all : base_path:string -> (credential list, string) result
(** [load_all ~base_path] loads all credentials from
    [.masc/config/credentials.toml]. *)

val save_all : base_path:string -> credential list -> (unit, string) result
(** [save_all ~base_path credentials] saves all credentials to
    [.masc/config/credentials.toml]. *)

val find : base_path:string -> string -> (credential, string) result
(** [find ~base_path id] finds a credential by [id]. *)

val add : base_path:string -> credential -> (credential, string) result
(** [add ~base_path credential] adds a new credential. Returns an error if a
    credential with the same [id] already exists. *)

val remove : base_path:string -> string -> (unit, string) result
(** [remove ~base_path id] removes a credential by [id]. *)
