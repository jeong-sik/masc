(** Provider-neutral anchored iterative compaction and deterministic
    microcompaction for a Keeper's conversation history.

    {1 Core invariants}
    - {b Immutable anchors with lossless pointers}: each compaction epoch folds
      only the newly evicted turn span into an immutable {!compaction_anchor}
      whose source-attributed transcript observations carry canonical {!Ids.Turn_id.t}
      pointers back to archived raw turns stored verbatim in per-Keeper SQLite
      WAL ([<keepers_dir>/<keeper_id>.compaction.db]).
    - {b Structural triggers only}: compaction triggers strictly from an
      explicit provider hard-context limit or typed [ContextOverflow]
      ({!compaction_trigger}). Cumulative turn, time, token, or cost gates are
      forbidden.
    - {b Provider neutrality}: switching providers or models (e.g. 400K -> 128K,
      HTTP <-> ACP/CLI) projects seamlessly from the exact same canonical turns
      and immutable compaction anchor without cliff-dropping to zero history.
    - {b Off-domain WAL isolation}: every SQLite read and write executes off
      the main Eio domain via {!Domain_pool_ref.submit_io_or_inline} in SQLite
      WAL mode so readers never block writers or sibling Keepers. *)

module Turn_id := Ids.Turn_id

(** Immutable structured anchor carried across compaction epochs
    (Factory.ai / pi.dev / LCM pattern).

    When accumulated transcript observations exceed the provider's
    structural anchor budget, oldest entries roll off the pinned anchor into
    the immutable per-Keeper SQLite [compaction_epochs] / [archived_turns]
    history and [archived_epochs_through] records the highest epoch rolled off
    for lossless recall via {!load_archived_turn} and
    {!load_archived_turns_for_epoch}. *)
type compaction_anchor =
  { epoch_id : int
  ; covers_through_turn : Turn_id.t
  ; archived_epochs_through : int option
  ; active_intent : string
  ; observations : (Keeper_compaction_observation.t * Turn_id.t) list
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

(** One canonical Keeper turn consisting of its immutable identifier and
    ordered messages. *)
type canonical_turn =
  { turn_id : Turn_id.t
  ; messages : Agent_core.Types.message list
  }

(** Outcome of deterministic microcompaction over canonical turns. *)
type microcompaction_outcome =
  { turns : canonical_turn list
  ; externalized_count : int
  ; bytes_saved : int
  ; handles : Tool_output.artifact_ref list
  }

(** Provider-neutral projection outcome before invoking an anchor fold. *)
type projection_step =
  | Fits_verbatim of
      { anchor : compaction_anchor option
      ; retained_turns : canonical_turn list
      ; messages : Agent_core.Types.message list
      }
  | Fits_after_microcompaction of
      { anchor : compaction_anchor option
      ; retained_turns : canonical_turn list
      ; messages : Agent_core.Types.message list
      ; microcompacted : microcompaction_outcome
      }
  | Needs_compaction of
      { trigger : compaction_trigger
      ; previous_anchor : compaction_anchor option
      ; evicted_turns : canonical_turn list
      ; retained_turns : canonical_turn list
      ; microcompacted : microcompaction_outcome option
      }
  | Single_turn_exceeds_capacity of
      { capacity_bytes : int
      ; reserved_bytes : int
      ; smallest_turn_bytes : int
      }

(** Result of a full provider-neutral projection including anchored compaction
    when required by the target provider's hard limit. *)
type projected_context =
  { anchor : compaction_anchor option
  ; compacted_new_epoch : bool
  ; retained_turns : canonical_turn list
  ; evicted_turns : canonical_turn list
  ; messages : Agent_core.Types.message list
  ; microcompacted_results : int
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
  | Capacity_exceeded of
      { capacity_bytes : int
      ; reserved_bytes : int
      ; smallest_turn_bytes : int
      }

val store_error_to_string : store_error -> string

(** Register a process-wide callback notified whenever a new immutable
    compaction epoch commits (used by {!Keeper_memory_writers} to drive
    structural Librarian molting without a module cycle). Carries [keepers_dir]
    so multi-workspace hosts notify only the matching workspace. *)
val set_on_epoch_committed :
  (keepers_dir:string -> keeper_id:string -> compaction_anchor -> unit) option -> unit

(** Register an internal canonical-turn watermark observer notified with the
    exact [keepers_dir], [keeper_id], committed [anchor], and [evicted_turns]
    whenever {!commit_epoch} succeeds (used by {!Keeper_canonical_turn_store}
    to align [compact_evicted_messages] anchors with canonical turn sequences
    without creating a module cycle). *)
val set_on_canonical_epoch_committed :
  (keepers_dir:string
   -> keeper_id:string
   -> anchor:compaction_anchor
   -> evicted_turns:canonical_turn list
   -> unit)
    option
  -> unit

(** Strict JSON codecs (fail-closed on unknown/missing fields). *)
val anchor_to_json : compaction_anchor -> Yojson.Safe.t
val anchor_of_json : Yojson.Safe.t -> (compaction_anchor, string) result

val trigger_to_json : compaction_trigger -> Yojson.Safe.t
val trigger_of_json : Yojson.Safe.t -> (compaction_trigger, string) result

(** Render an immutable {!compaction_anchor} as a pinned [Agent_core.Types.message]
    tagged with {!Runtime_model_input_tail_window.compaction_anchor_metadata}. *)
val anchor_to_message : compaction_anchor -> Agent_core.Types.message

(** {1 Pure Incremental Anchored Fold} *)

(** Incrementally fold only [evicted_turns] onto [previous_anchor] via a caller
    summarizer callback (which returns observations from the supplied span), enforcing monotonic [epoch_id], canonical
    [covers_through_turn], and preservation of prior lossless turn pointers. *)
val fold_evicted_span
  :  ?previous_anchor:compaction_anchor
  -> evicted_turns:canonical_turn list
  -> summarize:
       (previous:compaction_anchor option
        -> evicted:canonical_turn list
        -> (compaction_anchor, string) result)
  -> unit
  -> (compaction_anchor, string) result

(** Deterministic pure structural folder extracting tool requests, typed tool
    responses and attributed assistant statements in the supplied span with canonical
    {!Ids.Turn_id.t} pointers. Used when no LLM summarizer is attached or as
    a deterministic structural baseline. *)
val deterministic_fold
  :  previous:compaction_anchor option
  -> evicted:canonical_turn list
  -> (compaction_anchor, string) result

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

(** Pure lossless roll-off: when [measure_message_bytes (anchor_to_message anchor)]
    exceeds [max_anchor_bytes], drop oldest entries from the heaviest observation type (recording [archived_epochs_through]) so the pinned anchor fits
    within [max_anchor_bytes] while earlier epochs remain losslessly retrievable
    from SQLite via {!load_archived_turn} / {!load_archived_turns_for_epoch}. *)
val bound_anchor_to_budget
  :  measure_message_bytes:(Agent_core.Types.message -> int)
  -> max_anchor_bytes:int
  -> compaction_anchor
  -> compaction_anchor

(** {1 Deterministic Microcompaction} *)

(** Externalize aged large [ToolResult] text bodies from turns strictly older
    than the trailing [keep_recent_turns] active turns into typed structured
    blob handles ({!Tool_output.encode_structured_handle}) persisted via
    {!Tool_blob_store.put_durable} with smart 4 KiB head+tail previews. Only
    replaces a body when the encoded structured handle is strictly smaller than
    the original body. Durable turns are never mutated.

    Note: [microcompact_turns] and {!compact_and_project} provide the
    module-level provider-neutral pipeline; the live turn driver
    ({!Keeper_turn_driver_try_provider}) currently invokes
    {!compact_evicted_messages} for eviction anchoring/archiving alongside
    {!Keeper_model_input_demotion} and {!Tool_blob_store} capture. *)
val microcompact_turns
  :  ?redact:Keeper_secret_redaction.t
  -> blob_store:Tool_blob_store.t
  -> keep_recent_turns:int
  -> canonical_turn list
  -> microcompaction_outcome

(** {1 Provider-Neutral Projection} *)

(** Plan projection of [anchor] + [turns] for a target provider capacity.
    First tries verbatim, then deterministic microcompaction (when [blob_store]
    is supplied), and finally splits off the minimal oldest prefix that allows
    the newest suffix to fit instead of cliff-dropping to zero turns. *)
val project_for_provider
  :  ?redact:Keeper_secret_redaction.t
  -> ?blob_store:Tool_blob_store.t
  -> ?keep_recent_turns:int
  -> anchor:compaction_anchor option
  -> measure_message_bytes:(Agent_core.Types.message -> int)
  -> capacity_bytes:int
  -> reserved_bytes:int
  -> canonical_turn list
  -> projection_step

(** {1 Per-Keeper SQLite WAL Store (Off-Domain via Domain_pool_ref)} *)

(** Filename suffix of a Keeper's compaction WAL database ([".compaction.db"]),
    registered with {!Server_tool_blob_scope} for blob-sweep reference scanning. *)
val db_suffix : string

(** Path to the Keeper's dedicated compaction WAL database:
    [<keepers_dir>/<keeper_id>.compaction.db]. *)
val db_path : keepers_dir:string -> keeper_id:string -> string

(** Decode all live JSON payloads holding blob references in a compaction WAL
    database ([active_microcompacted_handles], [compaction_epochs], and
    [archived_turns]) for {!Tool_blob_maintenance} sweep-root scanning. *)
val decode_live_blob_references_json : string -> (Yojson.Safe.t option, string) result

(** Read the latest committed compaction anchor for [keeper_id], or [Ok None]
    when no epoch has been committed yet. Non-blocking SQLite WAL read executed
    off-domain via {!Domain_pool_ref.submit_io_or_inline}. *)
val latest_anchor
  :  keepers_dir:string
  -> keeper_id:string
  -> (compaction_anchor option, store_error) result

(** List all immutable compaction epochs for [keeper_id] in ascending
    [epoch_id] order. *)
val list_epochs
  :  keepers_dir:string
  -> keeper_id:string
  -> (compaction_anchor list, store_error) result

(** Read-only summary of [<keepers_dir>/<keeper_id>.compaction.db] for
    dashboard/TUI Memory OS internals observability. Never creates a missing
    database file. *)
type stats =
  { present : bool
  ; epoch_count : int
  ; latest_anchor : compaction_anchor option
  ; archived_turns_count : int
  ; anchor_bytes : int
  }

val inspect_stats
  :  keepers_dir:string
  -> keeper_id:string
  -> (stats, store_error) result

(** Losslessly retrieve an archived verbatim turn by its canonical
    {!Ids.Turn_id.t} pointer from the compaction WAL store. *)
val load_archived_turn
  :  keepers_dir:string
  -> keeper_id:string
  -> turn_id:Turn_id.t
  -> (canonical_turn option, store_error) result

(** Retrieve all archived verbatim turns belonging to [epoch_id] in canonical
    sequence order. *)
val load_archived_turns_for_epoch
  :  keepers_dir:string
  -> keeper_id:string
  -> epoch_id:int
  -> (canonical_turn list, store_error) result

(** Atomically commit an immutable compaction epoch together with its verbatim
    archived turns inside a single SQLite WAL transaction off-domain. Applies
    {!Keeper_secret_redaction} before persisting raw messages and anchor text. *)
val commit_epoch
  :  keepers_dir:string
  -> keeper_id:string
  -> trigger:compaction_trigger
  -> anchor:compaction_anchor
  -> evicted_turns:canonical_turn list
  -> (compaction_anchor, store_error) result

(** {1 End-to-End Compaction + Projection} *)

(** Project [turns] for a target provider ceiling, loading the latest persisted
    anchor from [<keepers_dir>/<keeper_id>.compaction.db] and, when
    {!Needs_compaction} (or an explicit [force_trigger] such as
    [Provider_context_overflow]) occurs, incrementally folding only the newly
    evicted span, committing the new immutable epoch atomically, optionally
    notifying [on_epoch_committed] (for Librarian structural molting), and
    returning the ready-to-send provider-neutral message list. *)
val compact_and_project
  :  ?redact:Keeper_secret_redaction.t
  -> ?blob_store:Tool_blob_store.t
  -> ?keep_recent_turns:int
  -> ?force_trigger:compaction_trigger
  -> ?summarize:
       (previous:compaction_anchor option
        -> evicted:canonical_turn list
        -> (compaction_anchor, string) result)
  -> ?on_epoch_committed:(compaction_anchor -> unit)
  -> keepers_dir:string
  -> keeper_id:string
  -> measure_message_bytes:(Agent_core.Types.message -> int)
  -> capacity_bytes:int
  -> reserved_bytes:int
  -> canonical_turn list
  -> (projected_context, store_error) result

(** Fold an evicted prefix of raw conversation messages (partitioned by
    {!Runtime_model_input_tail_window.annotate} atoms into canonical turns) onto
    the Keeper's latest persisted compaction anchor and commit a new immutable
    epoch into [<keepers_dir>/<keeper_id>.compaction.db] inside a single
    [BEGIN IMMEDIATE] SQLite transaction off-domain. Raw pre-microcompaction
    evicted turns are secret-redacted and archived verbatim independent of
    {!Tool_blob_store}. Always bounds the committed anchor via
    {!bound_anchor_to_budget} (falling back to {!default_anchor_max_bytes} when
    no provider limit is known). Idempotent: atoms already covered by
    [latest_anchor.covers_through_turn] are skipped, and an empty newly-evicted
    span returns [Ok None]. *)
val compact_evicted_messages
  :  ?redact:Keeper_secret_redaction.t
  -> ?blob_store:Tool_blob_store.t
  -> ?max_anchor_bytes:int
  -> ?measure_message_bytes:(Agent_core.Types.message -> int)
  -> ?on_epoch_committed:(compaction_anchor -> unit)
  -> keepers_dir:string
  -> keeper_id:string
  -> trigger:compaction_trigger
  -> evicted_messages:Agent_core.Types.message list
  -> unit
  -> (compaction_anchor option, store_error) result

(** Return the live post-compaction suffix of [messages] strictly after
    [anchor.covers_through_turn] (or strictly after the last inline compaction
    anchor message if present in [messages]). Returns [messages] unchanged if
    [anchor.covers_through_turn] does not match any atom/turn in [messages]. *)
val messages_after_anchor
  :  anchor:compaction_anchor
  -> Agent_core.Types.message list
  -> Agent_core.Types.message list

(** Read {!latest_anchor} for [keeper_id] and return {!messages_after_anchor}
    when a committed compaction epoch exists; otherwise returns [messages]
    unchanged (failing open on absent/unreadable store). *)
val live_history_after_latest_anchor
  :  keepers_dir:string
  -> keeper_id:string
  -> Agent_core.Types.message list
  -> Agent_core.Types.message list
