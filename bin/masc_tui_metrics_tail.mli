module Decode = Masc.Tui_decode

type row_error =
  | Malformed_json of {
      path : string;
      line_number : int option;
      detail : string;
    }
  | Invalid_metrics_row of {
      (** One-based chronological position inside the selected physical-row
          window; this is not a source-file line number. *)
      physical_index : int;
      detail : string;
    }

type load_error =
  | Storage_error of Dated_jsonl.read_error
  | Row_errors of {
      physical_rows : int;
      errors : row_error list;
    }

type snapshot = {
  entries : Decode.log_entry list;
  error : load_error option;
}

val empty : snapshot
val error_to_string : load_error -> string
(** Operator-facing diagnostic that delegates storage failures to
    [Dated_jsonl.read_error_to_string]. *)
val resolve_with :
  expected_keeper:string ->
  read_recent:(int -> (Dated_jsonl.recent_entry list, Dated_jsonl.read_error) result) ->
  limit:int ->
  snapshot
val load : store:Dated_jsonl.t -> expected_keeper:string -> limit:int -> snapshot
(** Read exactly the newest [limit] physical non-empty rows. Rejected rows
    and rows attributed to a different Keeper consume that bound and are
    reported; they are never backfilled. *)
val for_selection : load:('a -> snapshot) -> 'a option -> snapshot
val reconcile_selection :
  current:snapshot ->
  previous_keeper:string option ->
  selected_keeper:string option ->
  snapshot
(** Retain a cached snapshot only while the selected Keeper identity is
    unchanged. A missing or replacement selection clears the cache. *)
val content_height : terminal_rows:int -> error:load_error option -> int
val maximum_scroll : entry_count:int -> content_height:int -> int
val normalize_scroll : entry_count:int -> content_height:int -> int -> int
val scroll_up : entry_count:int -> content_height:int -> int -> int
val scroll_down : entry_count:int -> content_height:int -> int -> int
val empty_message : load_error option -> string
