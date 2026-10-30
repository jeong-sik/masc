(** Pure IDE projection of canonical Keeper tool-call rows. There is no
    separate event writer, observation queue or mutable-Git attribution here. *)
type event_kind = Tool
val event_kind_of_string : string -> event_kind option
val event_kind_to_string : event_kind -> string
val events_of_rows : Yojson.Safe.t list -> (Yojson.Safe.t list, string) result
(** Each event retains the actual canonical execution identity as [event_id]
    and the producer's physical turn reference as [turn_id]. Invalid metadata
    rejects the complete page instead of silently dropping facts. *)
