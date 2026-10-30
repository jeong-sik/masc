(** Idempotent projections of an immutable Failed operation. The operation
    store owns the verdict; journal and transcript are recoverable views of it.
    No model judgment, admission lookup, or operation mutation occurs here. *)
type error =
  | Invalid_identity of string
  | Transcript_unavailable of string
  | Journal_unavailable of string

type outcome =
  | Not_failed
  | Projected of
      { transcript : (unit, error) result
      ; journal : (Keeper_chat_event_log.terminal_error_receipt, error) result
      }

val error_to_string : error -> string
val persist :
  base_path:string -> keeper_name:string -> Keeper_chat_operation.t ->
  (outcome, error) result
(** Both independent projections are attempted. A failed transcript cannot
    suppress a durable journal terminal. Only a successful journal receipt may
    authorize its live wire event. Each successful effect survives another
    projection's failure; retry the same immutable operation on recovery. *)
val persist_all :
  base_path:string -> keeper_name:string -> Keeper_chat_operation.t list ->
  (Keeper_chat_operation.t * (outcome, error) result) list
(** {!persist} for every operation, with one read of the Keeper's transcript
    for all of them ({!Keeper_chat_store.append_settled_failures_once}) instead
    of one read per operation. Each operation gets one answer: those that are
    not Failed or whose identity is invalid first, then the Failed ones in
    order. A transcript that cannot be read or written fails every Failed
    operation's transcript projection; each journal is still attempted. *)
