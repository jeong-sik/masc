(** Response type that carries a CWD value visible to keepers
    and a host-side path for operator logging. *)

type t =
  | Host_path of { abs : string }
  | Sandboxed of { host_abs : string; container_abs : string }

(** [of_sandbox ~sandbox ~host_cwd ~container_cwd_for_docker] builds
    a {!t} according to where the sandbox's tree lives: a host path when
    the endpoint owns it, a container path for a shared mount. *)
val of_sandbox
  :  sandbox:Keeper_sandbox.t
  -> host_cwd:string
  -> container_cwd_for_docker:string
  -> t

(** [keeper_visible t] returns the path string to hand to a keeper —
    container_abs for a shared mount, abs for a host path. *)
val keeper_visible : t -> string

(** [operator_host t] returns the host-side absolute path for
    operator logging — host_abs for a shared mount, abs for a host path. *)
val operator_host : t -> string

(** [to_yojson_response t] serialises the keeper-visible path as a
    JSON string for tool response bodies. *)
val to_yojson_response : t -> [> `String of string]
