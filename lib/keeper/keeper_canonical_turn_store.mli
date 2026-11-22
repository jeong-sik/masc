(** Unified per-Keeper Canonical Turn Store (SQLite WAL, off-domain).

    Single authoritative append-only turn journal shared across all Keeper
    runtimes ({!Agent_core_http}, {!Acp_cli}, {!Official_cli}) stored at
    [<keepers_dir>/<keeper_id>.canonical-turns.db] and registered in
    {!Server_tool_blob_scope}.

    {1 Invariants}
    - {b Cross-runtime continuity}: both Agent Core HTTP turns and ACP/Official
      CLI turns commit canonically on completion, closing the failover black
      hole where CLI turns previously wrote no Agent Core checkpoint.
    - {b Off-domain SQLite WAL}: every SQLite read and write executes off the
      main Eio domain via {!Domain_pool_ref.submit_io_or_inline} with
      [PRAGMA busy_timeout=5000], [PRAGMA auto_vacuum=INCREMENTAL],
      [BEGIN DEFERRED] for read snapshots, and [BEGIN IMMEDIATE] for writes.
    - {b Bounded disk lifecycle & purge cleanup}: superseded rows are pruned
      atomically ([DELETE FROM canonical_turns WHERE seq <= cutoff_seq]) when
      {!record_compaction_watermark} or {!record_history_reset} advances the
      cutoff floor, {!commit_turn} enforces a declarative safety retention cap
      of {!max_retained_turns} ([2000] newest turns) when compaction has not
      run, [PRAGMA incremental_vacuum(64)] reclaims freed pages post-commit
      whenever rows are pruned, and {!delete_store} removes
      [<keeper_id>.canonical-turns.db] plus [-wal]/[-shm]/[-journal] sidecars
      during Keeper purge.
    - {b Provider-neutral handoff}: {!load_handoff_context} combines the latest
      immutable {!Keeper_compaction.compaction_anchor} with all verbatim
      canonical turns strictly after [anchor.covers_through_turn], preserving
      unbroken dialogue and tool context across HTTP <-> ACP/CLI failover. *)

module Turn_id := Ids.Turn_id

(** Closed algebraic sum of Keeper runtime families. *)
type runtime_kind =
  | Agent_core_http
  | Acp_cli
  | Official_cli

val runtime_kind_to_string : runtime_kind -> string
val runtime_kind_of_string : string -> (runtime_kind, string) result

(** One canonical committed Keeper turn persisted in SQLite WAL. *)
type canonical_turn =
  { turn_id : Turn_id.t
  ; parent_turn_id : Turn_id.t option
  ; runtime_kind : runtime_kind
  ; runtime_id : string
  ; user_input : string
  ; tool_calls_json : Yojson.Safe.t
  ; assistant_output : string
  ; usage_json : Yojson.Safe.t
  ; compaction_epoch_id : int option
  ; created_at : float
  }

(** Provider-neutral handoff projection combining the latest compaction anchor
    with verbatim canonical turns committed after [anchor.covers_through_turn]. *)
type handoff_context =
  { anchor : Keeper_compaction.compaction_anchor option
  ; turns_after_anchor : canonical_turn list
  ; messages : Agent_core.Types.message list
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

val store_error_to_string : store_error -> string

(** Filename suffix of a Keeper's canonical turn WAL database
    ([".canonical-turns.db"]), registered with {!Server_tool_blob_scope}. *)
val db_suffix : string

(** Path to the Keeper's dedicated canonical turn WAL database:
    [<keepers_dir>/<keeper_id>.canonical-turns.db]. *)
val db_path : keepers_dir:string -> keeper_id:string -> string

(** Declarative upper bound on canonical turn rows retained in
    [<keeper_id>.canonical-turns.db] ([2000] newest turns) when compaction has
    not pruned older rows. Enforced inside {!commit_turn} followed by
    [PRAGMA incremental_vacuum(64)] whenever rows are pruned. *)
val max_retained_turns : int

(** Remove [<keepers_dir>/<keeper_id>.canonical-turns.db] together with its
    SQLite sidecars ([-wal], [-shm], [-journal]) off-domain during Keeper
    purge. Idempotent when files are already absent. *)
val delete_store
  :  keepers_dir:string
  -> keeper_id:string
  -> (unit, store_error) result

(** Decode all live JSON payloads ([tool_calls_json], [usage_json]) stored in
    a canonical turn WAL database for {!Tool_blob_maintenance} sweep-root
    scanning. Executes a read-only [BEGIN DEFERRED] snapshot off-domain. *)
val decode_live_blob_references_json : string -> (Yojson.Safe.t option, string) result

(** Atomically commit one canonical turn into
    [<keepers_dir>/<keeper_id>.canonical-turns.db] inside a [BEGIN IMMEDIATE]
    WAL transaction off-domain. When [parent_turn_id] is omitted, resolves the
    current latest committed [turn_id] atomically inside the same transaction
    (falling back to the latest post-reset compaction watermark's last turn id
    after compaction pruning) so the parent chain remains unbroken across
    runtime failover and compaction. Enforces [max_retained_turns] (default
    {!max_retained_turns} = [2000]) and runs [PRAGMA incremental_vacuum(64)]
    post-commit whenever older rows are pruned. *)
val commit_turn
  :  keepers_dir:string
  -> keeper_id:string
  -> ?parent_turn_id:Turn_id.t
  -> turn_id:Turn_id.t
  -> runtime_kind:runtime_kind
  -> runtime_id:string
  -> user_input:string
  -> tool_calls_json:Yojson.Safe.t
  -> assistant_output:string
  -> usage_json:Yojson.Safe.t
  -> ?compaction_epoch_id:int
  -> ?max_retained_turns:int
  -> created_at:float
  -> unit
  -> (canonical_turn, store_error) result

(** Return the latest committed canonical turn for [keeper_id], or [Ok None]
    when no turns have been committed yet. *)
val latest_turn
  :  keepers_dir:string
  -> keeper_id:string
  -> (canonical_turn option, store_error) result

(** List all canonical turns for [keeper_id] in monotonic commit sequence order. *)
val list_turns
  :  keepers_dir:string
  -> keeper_id:string
  -> (canonical_turn list, store_error) result

(** Load canonical turns strictly after [after_turn_id] in commit sequence
    order. If [after_turn_id] is not present in the canonical store (for
    example, when an anchor covers turns recorded before canonical persistence),
    returns all canonical turns in sequence order so no recent turn is lost. *)
val load_turns_after
  :  keepers_dir:string
  -> keeper_id:string
  -> after_turn_id:Turn_id.t
  -> (canonical_turn list, store_error) result

(** Metadata key stamped on messages projected by {!messages_of_canonical_turn}
    so deduplication and compaction watermark matching recognize canonical turns
    structurally without string heuristics. *)
val canonical_turn_id_metadata_key : string

(** Project a single canonical turn into provider-neutral
    {!Agent_core.Types.message} records preserving user input, structured tool
    invocations, and assistant output. *)
val messages_of_canonical_turn : canonical_turn -> Agent_core.Types.message list

(** Record the exact canonical-turn sequence watermark covered by a committed
    compaction [anchor] and its [evicted_turns] into
    [<keepers_dir>/<keeper_id>.canonical-turns.db]. Registered automatically
    with {!Keeper_compaction.set_on_canonical_epoch_committed}. *)
val record_compaction_watermark
  :  keepers_dir:string
  -> keeper_id:string
  -> anchor:Keeper_compaction.compaction_anchor
  -> evicted_turns:Keeper_compaction.canonical_turn list
  -> (int64 option, store_error) result

(** Record an operator history-clear boundary ([reset_after_seq],
    [reset_after_anchor_epoch]) in [<keepers_dir>/<keeper_id>.canonical-turns.db]
    so subsequent {!load_handoff_context} and {!hydrate_missing_turns} calls
    never resurrect pre-clear compaction anchors or pre-clear canonical turns,
    and the next committed turn begins a fresh parent chain. *)
val record_history_reset
  :  keepers_dir:string
  -> keeper_id:string
  -> (unit, store_error) result

(** Rebind an already-committed ACP turn row ([from_turn_id]) to the canonical
    turn reference ([to_turn_id], i.e. [<trace_id>#<absolute_turn>]) and
    optionally clear [assistant_output] when a settled terminal effect
    suppressed visible replay prose. Preserves commit order, parent link,
    tool calls, and usage payloads. *)
val bind_turn_ref
  :  keepers_dir:string
  -> keeper_id:string
  -> from_turn_id:Turn_id.t
  -> to_turn_id:Turn_id.t
  -> suppress_assistant_output:bool
  -> unit
  -> (unit, store_error) result

(** Load the latest {!Keeper_compaction.latest_anchor} together with all
    verbatim canonical turns committed after [anchor.covers_through_turn]
    and after any recorded history-reset boundary, projected into
    provider-neutral messages for HTTP <-> ACP/CLI handoff. *)
val load_handoff_context
  :  keepers_dir:string
  -> keeper_id:string
  -> (handoff_context, store_error) result

(** Hydrate canonical turns (and compaction anchor when [existing_messages]
    has no non-system conversation turns) that are missing from
    [existing_messages], matching structurally by [canonical_turn_id] /
    [masc.bridged_turn_ref] metadata with an order-aware sequential legacy
    fallback so cross-runtime failover never duplicates or drops turns. *)
val hydrate_missing_turns
  :  keepers_dir:string
  -> keeper_id:string
  -> existing_messages:Agent_core.Types.message list
  -> (Agent_core.Types.message list, store_error) result
