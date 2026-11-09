(** Dashboard read model for autonomous keeper turns.

    The current {!Turn_record.t} owns the closed turn kind, keeper/agent
    identity, generation, and exact AGENT_CORE raw-trace run reference. This reader
    selects only [Autonomous] records and projects only that recorded run.
    Final text and typed execution steps come from the same exact raw trace;
    it never scans or concatenates provider runs. Tool steps carry a canonical
    execution id only when the declared execution ledger row matches the exact
    raw invocation occurrence. Inline composition child rows stay available to
    TurnRecord consumers but do not compete with top-level raw invocation slots.
    Ambiguous or missing evidence remains unlinked. *)

type turn =
  { turn_id : string
  ; started_at : float
  ; final_text : string option
  ; trace : Keeper_chat_blocks.trace_step list
  }

type snapshot
(** The existing retention-bounded recent TurnRecord rows, strictly decoded.
    A read handle does not register an append mutex or a Keeper store cache. *)

val read_snapshot_result :
  config:Workspace.config -> keeper_name:string -> ?previous:snapshot -> ?limit:int -> unit ->
  (snapshot, string) result
(** Reread the current bounded physical rows and all storage boundaries.
    [previous] reuses only an already strictly decoded snapshot for this Keeper
    when every selected source path and raw row is byte-identical. It does not
    skip a current read, weaken errors or authorize another Keeper's data. *)
val snapshot_has_records : snapshot -> bool
val snapshot_fingerprint : snapshot -> string
val project_snapshot_result :
  config:Workspace.config -> keeper_name:string -> snapshot ->
  (turn list, string) result
(** Project a previously read snapshot using the same optional exact-run and
    execution-link evidence rules as {!load_recent}. Missing/retired run
    evidence remains absent. Actual trace inspection/read/parse failures, store
    reads and invalid TurnRecords cannot become an empty successful history. *)

val load_recent :
  config:Workspace.config ->
  keeper_name:string ->
  ?limit:int ->
  ?since:float ->
  unit ->
  turn list
(** Returns exact-run autonomous turns oldest-first. [Autonomous] records with
    no exact run are a typed absence and are skipped without a warning.
    Strictly incompatible records, unexpectedly missing/non-regular referenced
    traces, and failed run summaries are logged and skipped. There is no legacy
    decoder or fallback classifier. *)
