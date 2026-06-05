(** Response type that carries a CWD value visible to keepers
    and a host-side path for operator logging. *)

type t =
  | Local of { abs : string }
  | Sandboxed of { host_abs : string; container_abs : string }

(** [local ~host_cwd] builds a local-backend CWD response. *)
val local : host_cwd:string -> t

(** [docker ~host_cwd ~container_cwd] builds a Docker-backed CWD response. *)
val docker : host_cwd:string -> container_cwd:string -> t

(** [of_sandbox ~sandbox ~host_cwd ~container_cwd_for_docker] builds
    a {!t} according to the backend kind (Local or Docker). *)
val of_sandbox
  :  sandbox:Keeper_sandbox.t
  -> host_cwd:string
  -> container_cwd_for_docker:string
  -> t

(** [profile_independent_cwd ~container_root ~host_cwd] checks whether
    [host_cwd] is already a container-side path that starts with
    [container_root]; returns [Some host_cwd] when it does, [None]
    otherwise. Acts as the middle fallback in {!container_cwd_of_host}. *)
val profile_independent_cwd
  :  container_root:string
  -> host_cwd:string
  -> string option

(** [keeper_visible t] returns the path string to hand to a keeper —
    container_abs for Docker, abs for Local. *)
val keeper_visible : t -> string

(** [operator_host t] returns the host-side absolute path for
    operator logging — host_abs for Docker, abs for Local. *)
val operator_host : t -> string

(** [to_yojson_response t] serialises the keeper-visible path as a
    JSON string for tool response bodies. *)
val to_yojson_response : t -> [> `String of string]
