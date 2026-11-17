(** The fixed host owner of declared media-reading originals. Callers hold
    the existing workspace process lease and serialize retains/progress.
    Discovery is an observation, not execution or retry authority. *)

type error =
  | Store_error of Lane_addon_tool_request_owner.error
  | Invalid_original of Keeper_media_reading_original.error
  | Store_workspace_mismatch of { expected : string; actual : string }
  | Invalid_reply of string
  | Reply_blob_missing of string
  | Reply_blob_unavailable of Tool_blob_store.fetch_error
  | Reply_blob_write_failed of string
  | Reply_update_error of Lane_addon_tool_request_owner.update_error

val error_to_string : error -> string
val scope : string

type retained
val record : retained -> Lane_addon_tool_request_owner.retained
val original : retained -> Keeper_media_reading_original.t

val check_retained :
  Lane_addon_tool_request_owner.retained -> (unit, string) result
(** Pure preflight check of the fixed host header and complete semantic body,
    request ID, digest, summary, original-bound approval facts and reply links.
    Reply validation checks the normalized reference, not blob availability.
    A dispatch
    fact requires its captured intent; a wait link is never an Allow. This does
    not observe the current workspace/queue or interpret an execution result
    as a reading. *)

val retain :
  store:Lane_addon_store.t -> Keeper_media_reading_original.t ->
  (retained, error) result
(** Reobserve the captured workspace before retaining through the existing
    store and strictly load that same ID afterwards. An error is not evidence
    of absent publication; resolve the same original with [load]. Never mint
    a replacement execution ID because a write returned an error. *)

val load :
  store:Lane_addon_store.t -> owner:Keeper_media_reading_original.owner ->
  request_id:string -> (retained option, error) result
(** [None] means this exact owner record is absent. It is not permission to
    replay a previously known execution. The current workspace and Keeper
    must match a restored original; source bytes and reader declarations are
    not read from the current runtime. *)

type reply_publication =
  | Stored of retained
  | Already_stored of retained
  | Unconfirmed of string

val retain_reply :
  store:Lane_addon_store.t -> expected:retained ->
  reply:Keeper_media_reading_reply.t -> (reply_publication, error) result
(** Reobserve the actual workspace, immutable original and current progress
    before writing. Current progress must preserve the supplied history as a
    prefix; a known fact cannot disappear on reload. A first reply requires
    the exact expected record in [Dispatch_pending]. Publish its complete canonical SDK-value bytes with
    [Tool_blob_store.put_durable], then one [Judgment_retained] link through
    the existing owner. No SDK call or interpretation occurs here.

    An equal existing reply is fetched and verified before [Already_stored];
    later progress is preserved. A different second reply conflicts. A linked
    missing/corrupt blob is an error, never repaired by this call. [Unconfirmed]
    is an uncertain owner-link publication, not permission to repeat the MCP
    call. Retry only retention of the same reply under the same original.
    An error after publication is not evidence that the link is absent.
    Blob write [Sys_error] is typed; cancellation and other exceptions propagate.
    The caller holds the existing workspace process lease and serialization
    across blob publication and owner linkage. *)

val load_reply :
  store:Lane_addon_store.t -> retained ->
  (Keeper_media_reading_reply.t option, error) result
(** Reload the current original under its actual workspace authority, requiring
    that it preserves the supplied history as a prefix, then
    fetch and validate the complete linked blob. [None] means the current
    history has no reply fact; it never authorizes dispatch. A judged/commit
    phase without its valid reply link, or a missing/corrupt/unreadable linked
    blob, is an error. Neither the SDK decoder nor result interpretation runs. *)

module For_testing : sig
  val retain_reply :
    ?put_blob:(Tool_blob_store.t -> bytes:string -> mime:string ->
      Tool_output.artifact_ref) ->
    ?save:(Lane_addon_store.t -> scope:string -> request_id:string ->
      Yojson.Safe.t -> (unit, string) result) ->
    store:Lane_addon_store.t -> expected:retained ->
    reply:Keeper_media_reading_reply.t -> unit ->
    (reply_publication, error) result
  (** The production path with only blob publication and the existing owner's
      final record writer injectable. A writer may report an error after a
      real save to model lost acknowledgement. No port runs for an existing
      link or a rejected expected record. *)
end

type inventory
val originals : inventory -> retained list
val discover_subject :
  store:Lane_addon_store.t -> Keeper_media_reading_original.subject ->
  (inventory, error) result
(** Strictly inspect all metadata in the fixed scope before selecting this
    subject. Every header/summary and workspace identity is checked, including
    other Keepers; load and restore every body before selecting this subject.
    A valid-looking summary cannot hide a body by changing its subject.
    Malformed, replaced,
    vanished or unreadable records are errors, never an empty inventory.
    Reader revision and continuation channel do not select the subject.
    This reads all live bodies in the scope. Multiple originals remain
    visible; no first-match choice or progress
    transition is performed. Revalidate under the existing owner before any
    later effect. The supplied store must use this workspace's canonical
    lane-addon store path. *)
