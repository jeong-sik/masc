(** Read the physical recent-turn window for the operator API. Malformed JSON
    and incompatible records contribute to the skipped count; an unreadable
    store is an error, never an empty or apparently current reading. *)
val read :
  store:Dated_jsonl.t ->
  limit:int ->
  (Turn_record.t list * int, Dated_jsonl.read_error) result
