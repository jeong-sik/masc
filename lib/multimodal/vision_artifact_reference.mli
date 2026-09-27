(** Whether a vision "kept" artifact handle is still reachable from a turn
    the Keeper (or a reviewer) might act on. This is the lifetime contract a
    prune policy must consult before evicting a [store_kept] handle: a handle
    still mentioned somewhere in the durable-consumer registry below is one a
    later turn could hand back to [keeper_analyze_image]'s [artifact] field,
    so evicting it would turn a live reference into a load that still returns
    a typed {!Multimodal.Vision_artifact_store.Missing_artifact} -- correct,
    but a real loss, not a cleanup.

    Scope mirrors {!Tool_blob_maintenance}'s closed durable-consumer registry
    (gate, keeper runtime state/checkpoints, keeper_chat, messages, tool_calls,
    traces, wire-capture) so the two content-addressed stores agree on where a
    reference can legally live. The marker shape differs: a vision handle is
    embedded as a bare 64-hex-character string (see
    [keeper_vision_ingest.ml]'s [image_unread_placeholder ~handle] and
    [keeper_tool_in_process_runtime.ml]'s ["artifact", handle] success field),
    not through {!Tool_output}'s [_blob sha256=...] JSON marker, so this module
    does a literal substring scan rather than parsing that marker.

    This module only answers "is [handle] mentioned somewhere under
    [masc_dir]"; it deletes nothing and is not wired into [store_kept] or any
    prune path yet -- that is deliberately a separate, later change.

    Known gap (not silent): Board posts are not scanned by this first pass,
    unlike {!Tool_blob_maintenance}, which takes the caller's board-posts-file
    resolver as a parameter. A vision handle mentioned only in a Board post
    would be treated as unreferenced here. This is recorded so a caller that
    needs that coverage does not assume it exists. *)

type error =
  | Durable_source_read_failed of
      { path : string
      ; reason : string
      }

val error_to_string : error -> string

val durable_consumer_basenames : string list
(** The directory names under [masc_dir] this module scans, kept in sync by
    hand with {!Tool_blob_maintenance.durable_consumer_basenames} (that list
    is not exported; see the module-level gap note). A basename that does not
    exist under [masc_dir] holds no references and is not an error. *)

val is_referenced : masc_dir:string -> handle:string -> (bool, error) result
(** [is_referenced ~masc_dir ~handle] walks every tree named in
    {!durable_consumer_basenames} under [masc_dir] and reports whether
    [handle] appears as a substring of any regular file's content.

    Every entry directly under [masc_dir/keepers] whose basename ends in
    [".vision"] is excluded from the walk. This is a scan-cost skip, not a
    correctness requirement: the scan reads file *content*, never a
    filename, so a store file's own name (which
    {!Multimodal.Vision_artifact_store.path_of} sets to its own handle)
    cannot self-match on its own; the risk it guards against is a stored
    payload whose *bytes* happen to contain the handle's hex text, which real
    image bytes essentially never do. Skipping the tree avoids reading every
    kept artifact's full (potentially large) binary payload for a text
    substring that is not expected to appear there, and keeps "reachable"
    meaning "reachable from somewhere that is not the store itself" even in
    that degenerate case.

    Symlinks are not followed (a symlinked durable-consumer tree is treated
    as absent, matching the conservative posture: this predicate protects a
    handle by returning [true], so refusing to expand a symlink only ever
    widens candidates for keep, never for eviction).

    Returns [Ok false] only when every existing tree was fully read without
    finding [handle]. A read failure on a tree that does exist over-reports
    conservatively via [Error] rather than silently reporting unreferenced. *)
