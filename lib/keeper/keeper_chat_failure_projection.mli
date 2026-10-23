(** Idempotent projections of an immutable Failed operation. The operation
    store owns the verdict; journal and transcript are recoverable views of it.
    No model judgment, admission lookup, or operation mutation occurs here. *)
type outcome =
  | Not_failed
  | Projected of Keeper_chat_event_log.terminal_error_receipt

type error =
  | Invalid_identity of string
  | Transcript_unavailable of string
  | Journal_unavailable of string

val error_to_string : error -> string
val persist :
  base_path:string -> keeper_name:string -> Keeper_chat_operation.t ->
  (outcome, error) result
(** A failure row never consumes the unanswered user input. Its delivery key
    and the journal's operation/completed_at key survive process restart.
    Successful effects are retained when the later projection fails; retry the
    same immutable operation instead of constructing a new failure. *)
