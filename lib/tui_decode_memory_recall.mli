(** What the TUI reads from [GET /api/v1/runtime/config/memory-recall]: the
    memory recall gate as the server reads it now. The server's side is
    [Server_memory_recall_standing.to_yojson]; the words are
    {!Keeper_memory_recall_standing.reason_to_string}, so a reason this
    reader does not know is a response it refuses, not one it guesses at. *)

type memory_recall_reading =
  { mrr_lane : (unit, Keeper_memory_recall_standing.reason) result
        (** [Ok ()] when the lane has a key; otherwise why it has not. *)
  ; mrr_keepers : (string * Keeper_memory_recall_standing.t) list
        (** The Keepers the server has a declaration for, each once, in the
            order the server listed them. *)
  }

val decode_memory_recall_reading : Yojson.Safe.t -> (memory_recall_reading, string) result
(** [Error] names the first field that is missing or not what this reader
    expects: an unknown word, a Keeper listed twice, a field of the wrong
    type. *)
