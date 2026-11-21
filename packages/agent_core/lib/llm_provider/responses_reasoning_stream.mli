(** Immutable per-native-item reasoning reconciliation. Prefixes are compared
    only within the same channel and part index. Explicit snapshots cannot
    truncate or contradict already observed bytes. Omitted channels preserve
    previous evidence; full text outranks its summary, and opaque state wins:
    a replayed opaque item conflicts only when both deliveries carry the same
    non-blank [id] and the [encrypted_content] differs. Identity that is
    missing on either side is unknown, so the stored (done) item is kept
    instead of refusing the turn: the two capture paths key by different
    numbers, and a positional match is not evidence that the items are one. *)
type t
type update = Unchanged | Append of string | Replace of string | Redact of string
val empty : t
val describe : t -> string
(** Bounded, secret-free label of the stored opaque item for a failure record. *)
val delta : t -> channel:Responses_reasoning.channel -> part:int -> string
  -> (t * update, string) result
val part_done : t -> channel:Responses_reasoning.channel -> part:int -> string
  -> (t * update, string) result
val item : t -> Responses_reasoning.t -> (t * update, string) result
