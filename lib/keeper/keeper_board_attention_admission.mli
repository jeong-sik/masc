(** Process-scoped source admission; durable candidates and partitions remain
    the recovery authority after cancellation or process exit. Base paths use
    the registry's canonical workspace identity; invalid paths raise the same
    [Invalid_argument] as registry lookup. Mutex regions touch memory only. *)
type token
val reserve_batch : base_path:string -> candidate_ids:string list -> token
val owns : token -> string -> bool
val blocked : base_path:string -> candidate_id:string -> bool
(** [None] means a batch or another singleton already owns that candidate. *)
val acquire_singleton : base_path:string -> candidate_id:string -> token option
val release : token -> unit
