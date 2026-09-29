(** One captured workspace inventory shared by HTTP observation and the curator.
    Each store is read independently. Stored file bindings are not revalidated.
    Missing and unreadable stores remain explicit gaps. *)
type t

(** What one read of one store saw. [Missing] is a store with no file, which
    the store reads as fresh empty state. *)
type 'snapshot observation = Missing | Unavailable of string | Available of 'snapshot

type keeper =
  { keeper_id : string
  ; ordinary : Keeper_memory_os_current.t observation
  ; source_bound : Keeper_memory_source_current.t observation
  }

val collect : base_path:string -> (t, string) result
val keepers : t -> keeper list
(** Every discovered Keeper, in discovery order. *)
val fingerprint : t -> string
(** Stable identity of the captured inventory, excluding observation time. *)
val source_count : t -> int
val to_json : t -> Yojson.Safe.t
(** Model input with original sources, snapshot metadata and store gaps. *)
val proposal_json : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Bind a model proposal to this exact inventory. The proposal store still
    validates coverage; this operation does not establish semantic truth. *)
val http_json : base_path:string -> Yojson.Safe.t
