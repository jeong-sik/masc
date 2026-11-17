(** The fixed host owner of declared media-reading originals. Callers hold
    the existing workspace process lease and serialize retains/progress.
    Discovery is an observation, not execution or retry authority. *)

type error =
  | Store_error of Lane_addon_tool_request_owner.error
  | Invalid_original of Keeper_media_reading_original.error
  | Store_workspace_mismatch of { expected : string; actual : string }

val error_to_string : error -> string
val scope : string

type retained
val record : retained -> Lane_addon_tool_request_owner.retained
val original : retained -> Keeper_media_reading_original.t

val check_retained :
  Lane_addon_tool_request_owner.retained -> (unit, string) result
(** Pure preflight check of the fixed host header and complete semantic body,
    request ID, digest, summary and original-bound approval facts. A dispatch
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
