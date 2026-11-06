(** Count the Exact records and original execution links that no live
    original owns (RFC-0498 §4.4). Nothing is moved or deleted.

    Only a configured declaration whose package needs an original is counted:
    {!Server_workspace_memory_addon_validation.original_required} or
    {!Server_librarian_addon_validation.original_required}, the same answers
    the Exact authority gives. A request of that declaration without a live
    original ends as [Unowned], so its record and link are never read again.
    The Exact records and links are listed before the live originals, because
    an original is retained before its Exact run starts. *)

type report =
  { declarations : int
  ; live_originals : int
  ; exact_records : int
  ; exact_record_bytes : int64
  ; unowned_exact_records : int
  ; unowned_exact_record_bytes : int64
  ; proofs : int
  ; proof_bytes : int64
  ; unowned_proofs : int
  ; unowned_proof_bytes : int64
  }

type error = Census_unavailable of string
(** A directory, link or live original could not be read or has an unknown
    shape. The detail names the failure class only, never record contents. *)

val error_to_string : error -> string

val run :
  store:Lane_addon_store.t ->
  declarations:Lane_addon_config.declaration list ->
  (report, error) result
(** Blocking. Reads each counted link whole; call it off the server domain. *)

val run_for_workspace : Workspace.config -> (report, error) result
(** {!run} over the workspace's Lane store and its configured declarations. *)
