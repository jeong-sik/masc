(** One captured workspace inventory shared by HTTP observation and the curator.
    Each store is read independently. Stored file bindings are not revalidated.
    Missing and unreadable stores remain explicit gaps. *)
type t

val collect : base_path:string -> (t, string) result
val fingerprint : t -> string
(** Stable identity of the captured inventory, excluding observation time. *)
val source_count : t -> int
val to_json : t -> Yojson.Safe.t
(** Model input with original sources, snapshot metadata and store gaps. *)
val proposal_json : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Bind a model proposal to this exact inventory. The proposal store still
    validates coverage; this operation does not establish semantic truth. *)
val http_json : base_path:string -> Yojson.Safe.t

