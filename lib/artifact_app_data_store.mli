type error =
  | Invalid of string
  | Artifact_error of Published_artifact_store.error
  | Conflict of Artifact_app_data.t
  | Request_collision
  | Unavailable of string
  | Commit_uncertain of Artifact_app_data.t
val error_message : error -> string
val read : base_path:string -> actor:string -> Artifact_app_data.target ->
  (Artifact_app_data.t, error) result
val set : base_path:string -> actor:string -> Artifact_app_data.request ->
  (Artifact_app_data.t, error) result
(** Stable owned locks and atomic cursor replacement protect concurrent writers.
    Unknown commit outcomes require rereading; they are never retried here. *)
module For_testing : sig
  val set_with_rewrite_io : io:Fs_compat.private_jsonl_transaction_io_for_testing ->
    base_path:string -> actor:string -> Artifact_app_data.request ->
    (Artifact_app_data.t, error) result
end
