(** Provider-neutral anchored compaction of a Keeper's conversation history.

    {1 Core invariants}
    - {b Immutable anchors}: each compaction epoch folds only the newly evicted
      atoms onto an immutable {!compaction_anchor}. Each observation names the
      atom it came from ({!Keeper_compaction_atom.name}), and the atoms are
      archived verbatim in per-Keeper SQLite WAL
      ([<keepers_dir>/<keeper_id>.compaction.db]).
    - {b Coverage by name}: an anchor records the front of the conversation it
      covers as a {!Keeper_compaction_atom.coverage}, named by Keeper turn and
      atom ordinal, and each epoch records the kind of list it was written over
      ({!Keeper_compaction_atom.frame}). A producer reads the coverage of the
      latest epoch over its own kind of list; the per-turn consumer reads the
      latest epoch of either kind. Both find the boundary in their own message
      lists by reading message metadata; nothing is serialized or hashed to
      compare.
    - {b Structural triggers only}: compaction triggers strictly from an
      explicit provider hard-context limit or typed [ContextOverflow]
      ({!compaction_trigger}). Cumulative turn, time, token, or cost gates are
      forbidden.
    - {b Off-domain WAL isolation}: every SQLite read and write executes off
      the main Eio domain via {!Domain_pool_ref.submit_io_or_inline} in SQLite
      WAL mode so readers never block writers or sibling Keepers. *)

(** Immutable structured anchor carried across compaction epochs.

    When accumulated observations exceed the anchor budget, the oldest entries
    roll off the pinned anchor and [archived_epochs_through] records the
    highest epoch rolled off; the atoms stay in [archived_atoms]. *)
type compaction_anchor =
  { epoch_id : int
  ; coverage : Keeper_compaction_atom.coverage
  ; archived_epochs_through : int option
  ; active_intent : string
  ; observations : (Keeper_compaction_observation.t * Keeper_compaction_atom.name) list
  }

(** Closed sum of lawful compaction triggers. Only explicit provider context
    boundaries trigger compaction; cumulative turn/cost/time gates are absent
    by construction. *)
type compaction_trigger =
  | Provider_context_overflow of { provider_limit_tokens : int option }
  | Provider_counted_window of
      { used_tokens : int
      ; limit_tokens : int
      }
      (** An agent's own session reached its window by the tokens the agent
          counted ([usage_update.used] of an ACP client), before it refused
          anything. *)
  | Explicit_hard_limit of
      { capacity_bytes : int
      ; observed_bytes : int
      }

type store_error =
  | Sqlite_error of
      { operation : string
      ; detail : string
      }
  | Corrupt_record of
      { context : string
      ; detail : string
      }
  | Schema_not_current of
      { path : string
      ; found : int64
      }
      (** The database holds tables under a [user_version] this build does
          not read: a store written before the atom-coverage hard cut. Stop
          the server and delete the file with its [-wal]/[-shm]/[-journal]
          companions. *)
  | Invalid_eviction of string
      (** The producer named an atom index outside its own list. *)

val store_error_to_string : store_error -> string

(** Register a process-wide callback notified whenever a new immutable
    compaction epoch commits (used by {!Keeper_memory_writers} to drive
    structural Librarian molting without a module cycle). Carries [keepers_dir]
    so multi-workspace hosts notify only the matching workspace. *)
val set_on_epoch_committed :
  (keepers_dir:string -> keeper_id:string -> compaction_anchor -> unit) option -> unit

(** Register the canonical-turn watermark observer notified with each newly
    committed anchor (used by {!Keeper_canonical_turn_store} to prune the rows
    through the anchor's settled turn without a module cycle). *)
val set_on_canonical_epoch_committed :
  (keepers_dir:string -> keeper_id:string -> compaction_anchor -> unit) option -> unit

(** Strict JSON codecs (fail-closed on unknown/missing fields). *)
val anchor_to_json : compaction_anchor -> Yojson.Safe.t
val anchor_of_json : Yojson.Safe.t -> (compaction_anchor, string) result

val trigger_to_json : compaction_trigger -> Yojson.Safe.t
val trigger_of_json : Yojson.Safe.t -> (compaction_trigger, string) result

(** Render an immutable {!compaction_anchor} as a pinned [Agent_core.Types.message]
    tagged with {!Runtime_model_input_tail_window.compaction_anchor_metadata}. *)
val anchor_to_message : compaction_anchor -> Agent_core.Types.message

(** Fallback anchor byte ceiling used when a [Provider_context_overflow]
    trigger does not report an explicit provider token limit so pinned anchors
    never grow unbounded across compaction epochs. *)
val default_anchor_max_bytes : int

val compaction_bytes_per_token : int
val compaction_bytes_of_tokens : int -> int

(** Structural byte ceiling for a pinned compaction anchor derived strictly from
    the explicit provider window ([capacity_bytes - reserved_bytes]), preventing
    monotonic anchor growth from crowding out the live retained tail. *)
val anchor_budget_for_window : capacity_bytes:int -> reserved_bytes:int -> int

(** When [measure_message_bytes (anchor_to_message anchor)] exceeds
    [max_anchor_bytes], drop the oldest entries of the heaviest observation
    type (recording [archived_epochs_through]) until the pinned anchor fits,
    then shorten [active_intent] if it still does not. The dropped
    observations' atoms stay in [archived_atoms]. *)
val bound_anchor_to_budget
  :  measure_message_bytes:(Agent_core.Types.message -> int)
  -> max_anchor_bytes:int
  -> compaction_anchor
  -> compaction_anchor

(** {1 Per-Keeper SQLite WAL Store (Off-Domain via Domain_pool_ref)} *)

(** Filename suffix of a Keeper's compaction WAL database ([".compaction.db"]),
    registered with {!Server_tool_blob_scope} for blob-sweep reference scanning. *)
val db_suffix : string

(** Path to the Keeper's dedicated compaction WAL database:
    [<keepers_dir>/<keeper_id>.compaction.db]. *)
val db_path : keepers_dir:string -> keeper_id:string -> string

(** Decode the JSON payloads that can hold blob references
    ([compaction_epochs] anchors and [archived_atoms] messages) for
    {!Tool_blob_maintenance} sweep-root scanning. A store this build does not
    read is an [Error], so the sweep stops instead of deleting what it could
    not scan. *)
val decode_live_blob_references_json : string -> (Yojson.Safe.t option, string) result

(** Read the latest committed compaction anchor for [keeper_id], or [Ok None]
    when no epoch has been committed yet. Non-blocking SQLite WAL read executed
    off-domain via {!Domain_pool_ref.submit_io_or_inline}. *)
val latest_anchor
  :  keepers_dir:string
  -> keeper_id:string
  -> (compaction_anchor option, store_error) result

(** Read-only summary of [<keepers_dir>/<keeper_id>.compaction.db] for
    dashboard/TUI Memory OS internals observability. Never creates a missing
    database file. *)
type stats =
  { present : bool
  ; epoch_count : int
  ; latest_anchor : compaction_anchor option
  ; archived_atom_count : int
  ; anchor_bytes : int
  }

val inspect_stats
  :  keepers_dir:string
  -> keeper_id:string
  -> (stats, store_error) result

(** {1 Producers and the consumer} *)

(** [offered] without its synthetic preamble, and how many of its atoms the
    start projection [windowed] left out from the front. The official-client
    runtimes cut a Start seed this way. *)
val prefix_eviction_of_window
  :  offered:Agent_core.Types.message list
  -> windowed:Agent_core.Types.message list
  -> Agent_core.Types.message list * int

(** Fold the atoms of [messages] that [eviction] drops onto the Keeper's
    latest anchor and commit a new immutable epoch inside a single
    [BEGIN IMMEDIATE] SQLite transaction off-domain.

    [frame] is the kind of list [messages] is. Which atoms are already
    archived comes from the latest epoch committed over the same [frame]:
    atoms it covers, or archived past its boundary, are skipped. An epoch over
    the other kind counts its names in a different list, so it skips nothing
    here. When no evicted atom is new the call commits nothing and returns
    [Ok None]. The summary folds onto the latest epoch of either kind.

    The new atoms are secret-redacted and archived verbatim. The committed
    anchor is always bounded via {!bound_anchor_to_budget} (falling back to
    {!default_anchor_max_bytes} when no provider limit is known). *)
val compact_evicted_messages
  :  ?redact:Keeper_secret_redaction.t
  -> ?max_anchor_bytes:int
  -> ?measure_message_bytes:(Agent_core.Types.message -> int)
  -> ?on_epoch_committed:(compaction_anchor -> unit)
  -> keepers_dir:string
  -> keeper_id:string
  -> trigger:compaction_trigger
  -> frame:Keeper_compaction_atom.frame
  -> messages:Agent_core.Types.message list
  -> eviction:Keeper_compaction_atom.eviction
  -> unit
  -> (compaction_anchor option, store_error) result

(** The part of [messages] after both the front [anchor] covers
    ({!Keeper_compaction_atom.covered_end}) and the last inline compaction
    anchor message. Returns [messages] unchanged when neither is in it.
    Reads message metadata once; nothing is serialized or hashed. *)
val messages_after_anchor
  :  anchor:compaction_anchor
  -> Agent_core.Types.message list
  -> Agent_core.Types.message list

(** {!messages_after_anchor} under the latest epoch of either kind, or
    [messages] unchanged when no epoch is committed. The cut decides only
    which tools the next turn carries, so an epoch over the canonical turn
    list may cut the message history too. [Error] when the store cannot be
    read, for example {!Schema_not_current}. *)
val live_history_after_latest_anchor
  :  keepers_dir:string
  -> keeper_id:string
  -> Agent_core.Types.message list
  -> (Agent_core.Types.message list, store_error) result
