(** Durable Fleet delivery intentions. This ledger does not publish workspace
    messages or deliver transcripts. Runtime admission and the fleet drain must be connected for durable
    recipient projection and restart recovery.
    All I/O is blocking: callers use the existing host offload boundary. *)
module Request_id = Keeper_chat_delivery_identity.Request_id
type t
type recipient_state = Pending of string option | Accepted
type workspace_state = Uncommitted | Committed of int
type sender_authority = Keeper_sender | External_sender
val sender_snapshot : caller:string -> access:Lane_addon_sources.access -> registered:string list ->
  (sender_authority * string list,string) result
(** Use verified standing to classify the sender. An operator whose actor name
    happens to match a Keeper remains external and that Keeper receives the row. *)
type payload = {
  sender_authority : sender_authority;
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
(** Mutations only open an existing admitted journal. Missing operations return
    [Unknown_operation] without creating a directory, journal or lock file. *)
val commit : t -> caller:string -> operation_id:Request_id.t -> seq:int -> (receipt, error) result
val recipient_result : t -> caller:string -> operation_id:Request_id.t ->
  recipient:string -> recipient_state -> (receipt, error) result
(** Failures remain Pending. [Pending None] cannot erase a saved failed-attempt
    detail; that regression is [Conflict]. Accepted recipients are monotone;
    callers pass the same workspace_request_id to append_user_message_once on
    every attempt. *)
val complete : record -> bool
type recovery = {pending:receipt list;settled_with_cleanup:receipt list;rejected:(string * error) list}
val recover : t -> (recovery, error) result
(** Restart scans only durable pending markers, created before admission and
    retired after terminal journal commit. Full journals remain addressable for
    exact replay and audit; completed history is not reread on every pulse.
    Pending filenames must be exact lowercase SHA-256 journal identities.
    Missing, nonregular or malformed individual journals are returned in [rejected]
    without creating a replacement or discarding their marker; other recoverable
    operations remain scheduled. Failure to list the pending directory still
    refuses the scan as a whole. An existing empty
    pre-admission journal may retire its marker under the exclusive journal lock.
    Completed records with descriptor settlement failures are returned separately
    and never put back into the pending drain. *)

module For_testing : sig
  val create : root:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing -> t
  val recover : t -> after_scan:(unit -> unit) -> (recovery, error) result
  (** [after_scan] runs after journal names are captured, before any journal is
      opened, so fixtures can exercise disappearance during restart recovery. *)
end
