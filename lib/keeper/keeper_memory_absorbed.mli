(** Facts the librarian absorbed into a new claim (RFC-0456 §4.2).

    A fact a new claim names in [absorbs] leaves the current snapshot because
    the new claim now says it, not because it was wrong. Its row is kept here,
    in a per-keeper append-only [<keeper>.memory-absorbed.jsonl], so
    [keeper_memory_search] can still reach its text. The librarian writes the
    records inside the snapshot lock, before the snapshot is replaced; a failed
    write fails the pass, so no absorbed fact leaves the snapshot without its
    row here. The file is never rewritten or trimmed. *)

type record =
  { recorded_at : float (** Unix seconds, the librarian pass's clock. *)
  ; trace_id : string (** The librarian pass; empty when there is none. *)
  ; memory_id : string (** The absorbed fact. *)
  ; into : string (** The new claim that absorbed it. *)
  ; fact : Keeper_memory_os_types.fact (** The absorbed row as the snapshot held it. *)
  }

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** {1 Codec} *)

val record_to_json : record -> Yojson.Safe.t

(** Field-exact. [memory_id] must be the identity of [fact], [into] a memory
    identity other than [memory_id], and [recorded_at] finite. *)
val record_of_json : Yojson.Safe.t -> (record, Keeper_memory_os_types.wire_error) result

(** {1 Store} *)

type append_error =
  | Invalid_record of Keeper_memory_os_types.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

val append_error_to_string : append_error -> string

(** Every record in one write, or an error and nothing validated written. An
    empty list writes nothing. *)
val append_all
  :  keepers_dir:string
  -> keeper_id:string
  -> record list
  -> (unit, append_error) result

type read_error =
  | Not_json of string
  | Malformed of Keeper_memory_os_types.wire_error

val read_error_to_string : read_error -> string

(** Every line in file order, numbered from 1, each decoded or rejected on its
    own. A missing file is no records. *)
val read : keepers_dir:string -> keeper_id:string -> (int * (record, read_error) result) list
