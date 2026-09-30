(** Durable Fleet delivery intentions. This ledger does not publish workspace
    messages or deliver transcripts. Runtime admission and the fleet drain must be connected for durable
    recipient projection and restart recovery.
    All I/O is blocking: callers use the existing host offload boundary. *)
module Request_id = Keeper_chat_delivery_identity.Request_id
type t
type recipient_state = Pending of string option | Accepted
type workspace_state = Uncommitted | Committed of int
type payload = {
  caller : string;
  operation_id : Request_id.t;
  artifact_sha256 : string;
  content : string;
  recipients : string list;
}
type record = private {
  payload : payload;
  workspace_request_id : Request_id.t;
  workspace : workspace_state;
  recipients : (string * recipient_state) list;
}
type error = Invalid_input of string | Conflict | Unknown_operation | Corrupt of string | Io_error of string
  | Settlement_failed of {primary:error;cleanup:string}
(** [Conflict] means a stable operation was reused with another payload or a
    settled recipient/commit was contradicted. No mutation is made. *)
type receipt = { record : record; settlement_error : string option }
(** A successful append remains acknowledged even if descriptor cleanup fails.
    [settlement_error] is evidence to report, not authorization to replay. *)
val create : root:string -> t
val admit : t -> payload -> (receipt, error) result
(** Repeating the exact operation returns its existing identity and recipient
    snapshot. A later fleet roster never changes the admitted recipients. *)
val find : t -> caller:string -> operation_id:Request_id.t -> (receipt option, error) result
val commit : t -> caller:string -> operation_id:Request_id.t -> seq:int -> (receipt, error) result
val recipient_result : t -> caller:string -> operation_id:Request_id.t ->
  recipient:string -> recipient_state -> (receipt, error) result
(** Failures remain Pending. Accepted recipients are monotone; callers pass the
    same workspace_request_id to append_user_message_once on every attempt. *)
val complete : record -> bool
type recovery = {pending:receipt list;settled_with_cleanup:receipt list}
val recover : t -> (recovery, error) result
(** Restart scan returns unfinished workspace commits and recipient obligations.
    Malformed journals fail the authoritative scan; no record is discarded.
    Completed records with descriptor settlement failures are returned separately
    and never put back into the pending drain. *)

module For_testing : sig
  val create : root:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing -> t
end
