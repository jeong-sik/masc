(** Immutable per-native-item reasoning reconciliation. Prefixes are compared
    only within the same channel and part index. Explicit snapshots cannot
    truncate or contradict already observed bytes. Omitted channels preserve
    previous evidence; full text outranks its summary, and opaque state wins. *)
type t
type update = Unchanged | Append of string | Replace of string | Redact of string
val empty : t
val delta : t -> channel:Responses_reasoning.channel -> part:int -> string
  -> (t * update, string) result
val part_done : t -> channel:Responses_reasoning.channel -> part:int -> string
  -> (t * update, string) result
val item : t -> Responses_reasoning.t -> (t * update, string) result
