(** Whether a vision "kept" artifact handle is still reachable from a turn
    the Keeper (or a reviewer) might act on. This is the lifetime contract a
    prune policy must consult before evicting a [store_kept] handle: a handle
    still mentioned in a durable consumer is one a
    later turn could hand back to [keeper_analyze_image]'s [artifact] field,
    so evicting it would turn a live reference into a load that still returns
    a typed {!Multimodal.Vision_artifact_store.Missing_artifact} -- correct,
    but a real loss, not a cleanup.

    The caller passes the paths to read: {!Tool_blob_maintenance.consumer_paths}
    of the server's scope, so the two content-addressed stores agree on where
    a reference can legally live. The marker shape differs: a vision handle is
    embedded as a bare 64-hex-character string (see
    [keeper_vision_ingest.ml]'s [image_unread_placeholder ~handle] and
    [keeper_tool_in_process_runtime.ml]'s ["artifact", handle] success field),
    not through {!Tool_output}'s [_blob sha256=...] JSON marker, so this module
    does a literal substring scan rather than parsing that marker.

    This module only answers "is [handle] mentioned in one of these paths";
    it deletes nothing. *)

type error =
  | Durable_source_read_failed of
      { path : string
      ; reason : string
      }
  | Symlink_encountered of { path : string }
      (** A symlink was found somewhere under a scanned tree. See
          {!is_referenced}'s symlink note: this is not a read failure, but it
          is still surfaced as an error rather than silently skipped, because
          the caller must not treat it as "unreferenced". *)

val error_to_string : error -> string

val is_referenced : consumer_paths:string list -> handle:string -> (bool, error) result
(** [is_referenced ~consumer_paths ~handle] walks every file or tree in
    [consumer_paths] and reports whether [handle] appears as a substring of
    any regular file's content. A path that does not exist holds no
    references and is not an error. The scan reads file content, never a
    file name, so a store file named after its own handle
    ({!Multimodal.Vision_artifact_store.path_of}) does not match itself.

    Symlinks are never followed and never silently skipped either: if a
    consumer path, or anything under it, is a symlink, the scan
    stops and returns [Error (Symlink_encountered _)] instead of continuing
    past it. A symlink found on the walk could be the only path to a live
    mention -- masc-pro-builder's review (PR #39473) caught an earlier
    version of this module that skipped a symlinked tree silently, which let
    the sole reference underneath it go unseen and made a live handle read
    as [Ok false]. Since this predicate's job is "protect a handle by
    returning [true]", any state this module cannot fully verify must not be
    read as [false]; a caller must treat every [Error] here, including this
    one, as "do not evict".

    Returns [Ok false] only when every existing path was fully read, with no
    symlink anywhere in it, and [handle] was not found. Any read failure or
    encountered symlink over-reports conservatively via [Error] rather than
    silently reporting unreferenced. *)
