(** Private API-key storage shared by native setup clients. Secrets and file
    paths must never be included in HTTP receipts or errors. *)
type pending

type error = Invalid_secret | Private_storage_unavailable | Provider_not_http | Configuration_rejected | Configuration_changed
val error_message : error -> string
val save : secret:string -> unit -> (pending, error) result
val reference_path : pending -> string
val retain : pending -> unit
val remove_uncommitted : pending -> unit
val apply_to_provider : runtime_config_path:string -> provider_id:string -> expected_source_revision:string -> pending ->
  (Runtime.config_commit_receipt, error) result
