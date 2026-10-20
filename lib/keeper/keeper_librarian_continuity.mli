(** A saved working state and its exact conversation coverage, per runtime Keeper.
    Memory progress and queued-input pockets do not authorize this frontier. *)
type prepared
val path : config:Workspace.config -> keeper_name:string -> string
val read_in : keepers_dir:string -> keeper_name:string ->
  (Librarian_continuity_snapshot.t option, string) result
(** {!read} for a caller that holds the runtime keepers directory rather than a
    workspace config, as the offline checkpoint purge does. *)
val read : config:Workspace.config -> keeper_name:string ->
  (Librarian_continuity_snapshot.t option, string) result
type no_source =
  | Drained
      (** Every completed turn the boundary log states has been read. *)
  | Source_unreadable
      (** The checkpoint this trace names is absent, or the boundary lines do
          not cover its prefix. The backlog is unknown, not empty. *)
  | Empty_range
      (** The requested end sits at or behind the start. *)

type source =
  | Ready of prepared
  | No_source of no_source

val prepare_source : ?end_atom:int -> config:Workspace.config -> keeper_name:string ->
  trace_id:string -> unit -> (source, string) result
(** Read boundaries before the locked checkpoint. Supply previous valid state
    plus the suffix through the next real completed turn. Capacity is a ceiling,
    not a reason to include later turns. An explicit [end_atom] selects a prefix;
    an unpublished exact Memory receipt takes precedence over either choice.
    Pending in-flight atoms are excluded.

    A snapshot file that cannot be decoded is logged with its decode reason
    and treated as absent: the source starts at atom 0 and {!commit} replaces
    the file. A snapshot file that cannot be read stays an [Error].

    The {!no_source} reason is carried because one caller acts on it: a pass
    that narrowed its reads releases that limit when the backlog is
    {!Drained}, and an unreadable source is not evidence that it was. *)

val prepare : ?end_atom:int -> config:Workspace.config -> keeper_name:string -> trace_id:string -> unit ->
  (prepared option, string) result
(** {!prepare_source} for a caller that only asks whether there is work.
    [None] means no new complete coverage, whatever the reason. *)

val prompt_json : prepared -> Yojson.Safe.t
(** The prior working state and its exact unread records. The range's conversation reaches the
    prompt once, as the folded [conversation_history] rendered from
    {!messages}; tool payloads and reasoning blocks are not part of it. *)
val previous_working_state : prepared -> string option
(** The same validated prior state carried by {!prompt_json}, for volatile
    message-by-message inference. This does not grant publication authority. *)
val previous_unread_messages : prepared -> Keeper_librarian_unread.t list
(** Exact prior holes retained only when the previous snapshot fits. *)
val commit : config:Workspace.config -> keeper_name:string -> prepared:prepared ->
  new_unread_messages:Keeper_librarian_unread.t list -> working_state:string ->
  (Librarian_continuity_snapshot.t, string) result
(** Publication requires an exact continuity-owned Memory receipt, or coverage
    within the serial ordinary consumer's genuinely read interval, and uses
    snapshot CAS. New holes must name exact messages in the selected original
    range and are merged with prior snapshot holes. The inference caller owns
    actual exhausted-walk authority. This updates only the continuation's
    evidence, never Memory's already-read receipt, ledger or durable cursor. *)

val messages : prepared -> Agent_core.Types.message list
(** Exact new source atoms of the range. The pass renders them once, folded,
    for both Memory disposition and working-state inference. *)
val select_prefix : end_atom:int -> prepared -> (prepared, string) result
(** Clip the selected source using its frozen checkpoint and validated cuts,
    without reading storage again. The end must remain inside the selected
    interval. An exact recovery receipt keeps its entire original interval,
    taking precedence over the requested end as in {!prepare_source}.
    Publication still revalidates the original source and snapshot CAS. *)
val source_spans : ?include_unread:bool -> prepared ->
  (Keeper_librarian_task_context.scope * Agent_core.Types.message list) list
(** Ordered historical attribution and its exact selected messages, derived
    solely from the frozen checkpoint and boundaries. Narrowing clips spans;
    a missing admission witness stays unattributed. No current Task lookup.
    [include_unread=false] omits only exact holes in a recovered Memory receipt,
    for continuation after Memory has already accounted for the source. *)
val memory_sources : prepared -> (Keeper_librarian_unread.source list, string) result
val unread_message : prepared -> source:Keeper_librarian_unread.source ->
  reasons:Keeper_librarian_input_refusal.t list -> (Keeper_librarian_unread.t, string) result
(** Bind a refusal to one exact original message in this selected range. The
    caller must establish actual single-message exhaustion before calling. *)
val apply_memory_program :
  ?on_memory_committed:(unit -> unit) ->
  config:Workspace.config -> keeper_name:string -> prepared:prepared ->
  anchor:Keeper_memory_os_current.program_anchor ->
  program:Keeper_memory_os_program.t -> working_state:string -> unit ->
  (Librarian_continuity_snapshot.t, string) result
(** Publish the complete volatile program at the original atom boundary. The
    serial Librarian lane owns cursors and excludes destructive purge. Recheck
    the selected checkpoint prefix and boundary generation under the stable
    session lock, then hold continuity CAS ownership across Memory publication.
    Normal checkpoint/boundary suffix appends are permitted. No inference runs
    under these locks. Memory's WAL repairs interruption before continuity save;
    the callback observes Memory durability, not continuity save success. *)
type turn_window = { after : float option; through : float }
val turn_window : prepared -> turn_window option
(** The recorded times of the turn-end lines that bound this unit's turn:
    [after] is the line at or before its start ([None] from atom 0), [through]
    the line that ends it. A Memory pass reads the counterpart observations
    of that span, as the durable pass does for the same atoms. A unit that
    stops inside its turn has none; the unit that finishes the turn carries
    the whole turn's span. *)
val turn_ref : prepared -> Ids.Turn_ref.t
val start_atom : prepared -> int
val completed_end_atom : prepared -> int
val end_atom : prepared -> int
val fit : fits:(prepared -> (bool, string) result) -> prepared ->
  (prepared option, string) result
(** Keep the selected work unit unchanged when it fits. Only an oversized unit
    is split at whole-atom midpoints, stopping at the first fitting part without
    growing it back toward the limit. Source bytes and prior state stay intact;
    an exact Memory recovery range cannot be split. *)
val narrow : prepared -> prepared option
(** Retry a refused source at the midpoint between whole atoms. Call only after
    a typed capacity refusal; [None] means one indivisible atom remains, or the exact range already has
    a Memory receipt that must be recovered without reapplying a smaller range. *)
val memory_range_id : config:Workspace.config -> keeper_name:string -> prepared ->
  (Keeper_memory_os_current.durable_range_id, string) result
(** Uses the continuity path as receipt scope. Never advances the ordinary
    completed-turn consumer's cursor or overwrites its proof. *)
val memory_committed : config:Workspace.config -> keeper_name:string -> prepared ->
  (bool, string) result
