(** Shared failure classification for content-addressed blob lookups.

    An absent sha256 fails as {!Tool_result.Workflow_rejection} regardless of
    which keeper tool resolved the digest, so [config/prompts/tool_failure.md]
    guides the caller uniformly whether the blob was never exported or expired
    from the store (#49454). *)

type t =
  | Absent
  | Malformed_sha256
  | Unreadable

val failure_class : t -> Tool_result.tool_failure_class

val of_blob_store_error : Tool_blob_store.fetch_error -> t

val failure_class_of_blob_store_error :
  Tool_blob_store.fetch_error -> Tool_result.tool_failure_class
