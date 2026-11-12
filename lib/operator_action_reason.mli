(** One immutable reported cause. This is evidence and a read destination,
    never authority to replay, acknowledge, cancel or change a Keeper. *)
type cause =
  | Memory_attention of {
      keeper : string;
      durable : Keeper_librarian_pending.t option;
      admission : Keeper_librarian_pending.admission option;
      measured_at : float option;
    }
  | Shutdown_fenced_backlog of {
      count : int;
      keepers : (string * int) list option;
      complete : bool;
    }
  | Other_reported

type t = private { component : string; reason : string; cause : cause }

val other : component:string -> reason:string -> t
val diagnostic : t -> string
val memory_attention :
  keeper:string -> durable:Keeper_librarian_pending.t option ->
  admission:Keeper_librarian_pending.admission option -> measured_at:float option -> t
val shutdown_fenced_backlog : count:int -> keepers:(string * int) list option -> complete:bool -> t
val queue_keepers : count:int -> Yojson.Safe.t -> (string * int) list option
(** [None] if identities/counts are missing, duplicate or do not add up.
    An ambiguous aggregate must not choose a Keeper. *)
val equal : t -> t -> bool
(** The complete original observation, including request identity and time. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Strict known causes; unknown kinds retain only their original diagnostic
    and grant no typed target. *)
val read_collection :
  diagnostics:string list -> Yojson.Safe.t -> (t list, string) result
(** The same ordered collection as the declared diagnostics. A malformed known
    cause is an error, never a guessed target. Repeated diagnostics retain
    their original occurrences rather than claiming they share an identity. *)
