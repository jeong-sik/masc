(** Read the physical recent-turn window for the operator API. Malformed JSON
    and incompatible records contribute to the skipped count; an unreadable
    store is an error, never an empty or apparently current reading. *)
val read :
  store:Dated_jsonl.t ->
  limit:int ->
  (Turn_record.t list * int, Dated_jsonl.read_error) result

type exact_error =
  | Store_read_failed of Dated_jsonl.read_error
  | Invalid_target_record of string
  | Uncertain_absence of { unidentified_rows : int }

val exact_error_to_string : exact_error -> string

val read_exact :
  store:Dated_jsonl.t ->
  keeper:string ->
  turn_ref:Ids.Turn_ref.t ->
  (Turn_record.t option * int, exact_error) result
(** Reverse-stream the canonical store until the complete [turn_ref] matches.
    The writer owns one record per Keeper turn. The second result counts
    malformed rows encountered before the match, without discarding a known
    positive because unrelated rows are damaged. A row naming the target but
    failing record/keeper validation is an error. [Ok (None, 0)] is a fully
    readable miss; unidentified rows make absence uncertain instead.

    There is no recent-page or time-window cutoff. Memory is bounded by the
    store's reverse-read chunk; an old or absent target can scan all history. *)
