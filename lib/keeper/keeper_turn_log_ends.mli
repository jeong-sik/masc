(** Where a Keeper's input stores other than its Agent-Core history end
    (RFC librarian-call-only-proposes §5.1).

    The two official-client files and the chat file end just after their
    last line break, not at their length: a row caught half written is on
    neither side of a mark. The external store ends at the number of whole
    rows it holds, blank rows included, the way the store numbers its rows.

    Each file is read under the lock its own store writes under. A file
    that is not there yet ends at 0. *)

type t =
  { history_bytes : int
  ; internal_bytes : int
  ; chat_bytes : int
  ; external_rows : int
  }

type store =
  | Official_history
  | Official_internal
  | Chat
  | External

val store_to_string : store -> string

(** The store is there and its end was not read. *)
type error =
  { store : store
  ; path : string
  ; detail : string
  }

val error_to_string : error -> string

(** [session_dir] holds the two official-client files. The chat and external
    files are the Keeper's own under [base_path]. *)
val read
  :  session_dir:string
  -> base_path:string
  -> keeper_name:string
  -> (t, error) result
