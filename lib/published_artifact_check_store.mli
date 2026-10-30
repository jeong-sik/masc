(** Durable explicit checks, shared by all authorized clients in one workspace.
    No publication or chat event is emitted. *)
type error =
  | Invalid of string
  | Artifact_error of Published_artifact_store.error
  | Conflict of Published_artifact_check.t option
  | Unavailable of string
  | Commit_uncertain of Published_artifact_check.t
type listing =
  { checks : Published_artifact_check.t list
  ; diagnostics : (string * string) list }

val error_message : error -> string
val list : base_path:string -> (listing, error) result
(** A successful listing with no diagnostics is authoritative for missing check
    records. Failed or partial reads must remain unknown in clients. *)
val set : base_path:string -> actor:string -> Published_artifact_check.request ->
  (Published_artifact_check.t, error) result
(** Verifies the exact published revision and digest before an atomic replacement
    at the exact stable-lock file cursor. A published rename whose durability or
    settlement is uncertain returns [Commit_uncertain]; reread before retrying.
    Unchecking persists a new change ID rather than deleting state. *)

module For_testing : sig
  val set_with_rewrite_io : io:Fs_compat.private_jsonl_transaction_io_for_testing ->
    base_path:string -> actor:string -> Published_artifact_check.request ->
    (Published_artifact_check.t, error) result
  (** The production transaction with injected rewrite descriptor settlement. *)
end
