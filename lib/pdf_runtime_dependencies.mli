(** Host commands used by PDF evidence inspection. Dependency availability is
    distinct from an actual PDF inspection or a completion verdict. *)
val commands : string list
val missing : unit -> string list

type t
val observe : unit -> t
(** Resolve and actually run each command's version entry point, using the
    scrubbed subprocess environment. No installation or document mutation. *)
val available : t -> bool
val to_json : t -> Yojson.Safe.t
