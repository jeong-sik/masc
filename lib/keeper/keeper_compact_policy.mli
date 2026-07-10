(** Keeper_compact_policy — compaction gate and strategy application.

    Decides whether compaction should run based on ratio/message/token
    gates and cooldown, then applies OAS strategies + persona fold.

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

(** Fraction of context window at which compaction is treated as an
    emergency, bypassing the continuity-reflection cooldown gate.

    Env override: [MASC_KEEPER_EMERGENCY_COMPACT_RATIO_THRESHOLD]
    (default 0.8, valid range \[0.5, 0.99\]; out-of-range falls back
    to default with warn). Read once at module init; restart required
    to change. Effective value is exported as Otel_metric_store gauge
    {!Keeper_metrics.(to_string EmergencyCompactRatioThreshold)}. *)
val emergency_compact_ratio_threshold : float

(** Typed result for the compaction policy gate. String rendering is kept
    at telemetry/persistence boundaries via {!compaction_decision_to_string}. *)
type compaction_decision =
  | Applied of Compaction_trigger.t
  | Blocked_below_thresholds
  | Skipped_no_checkpoint
  | Skipped_cooldown of
      { hold_s : float
      ; cooldown_sec : int
      }

val compaction_decision_to_string : compaction_decision -> string
val compaction_decision_applied : compaction_decision -> bool

(** Pure compaction gate decision. Exposed so the FSM-level cooldown
    contract can be tested without constructing an OAS checkpoint or
    running reducers. *)
val decide_compaction
  :  ratio:float
  -> msg_count:int
  -> tok_count:int
  -> ratio_gate:float
  -> message_gate:int
  -> token_gate:int
  -> cooldown_sec:int
  -> last_compaction_ts:float
  -> now_ts:float
  -> compaction_decision

(** Project [meta] to its [(ratio_gate, message_gate, token_gate)]
    tuple. *)
val compaction_policy_of_keeper : Keeper_meta_contract.keeper_meta -> float * int * int

(** OAS strategy chain used by checkpoint compaction before the
    keeper-private tool-result fold reducer. *)
val checkpoint_compaction_strategies
  :  mode:Keeper_config.compaction_mode
  -> Context_compact_oas.strategy list
(** OAS strategy chain for checkpoint compaction, selected by the
    per-keeper [compaction_mode]. [Deterministic] returns the extractive
    chain; [Llm] delegates to the same chain in W1 (no summarizer wired
    yet) and is replaced by the librarian-lane call in W2. *)

(** [compact_if_needed_typed ~meta ~now_ts ctx] evaluates the compaction
    gates and either returns [ctx] unchanged or applies the OAS
    strategy chain plus the keeper-private fold reducer.

    Return triple:
    - the (possibly compacted) working context;
    - [Some trigger] when compaction was applied, [None] otherwise;
    - a typed decision tag describing the gate outcome. *)
val compact_if_needed_typed
  :  meta:Keeper_meta_contract.keeper_meta
  -> now_ts:float
  -> Keeper_context_core.working_context
  -> Keeper_context_core.working_context
     * Compaction_trigger.t option
     * compaction_decision

(** Compatibility wrapper around {!compact_if_needed_typed}; the third
    return value is {!compaction_decision_to_string}.  The [string option]
    in the second position is the human-readable rendering of the
    {!Compaction_trigger.t} (via {!Compaction_trigger.to_human}). *)
val compact_if_needed
  :  meta:Keeper_meta_contract.keeper_meta
  -> now_ts:float
  -> Keeper_context_core.working_context
  -> Keeper_context_core.working_context * string option * string

type pre_compact_event = {
  timestamp : float;
  keeper_name : string;
  context_ratio : float;
  message_count : int;
  token_count : int;
  strategies : string list;
  context_window : int;
  is_local_model : bool;
  trigger : Compaction_trigger.t;
}

val record_pre_compact_callback :
  keeper_name:string ->
  context_ratio:float ->
  message_count:int ->
  token_count:int ->
  strategies:string list ->
  context_window:int ->
  is_local_model:bool ->
  trigger:Compaction_trigger.t ->
  pre_compact_event option

(** Replace [record_pre_compact_callback] with [f]. *)
val register_record_pre_compact :
  (keeper_name:string ->
   context_ratio:float ->
   message_count:int ->
   token_count:int ->
   strategies:string list ->
   context_window:int ->
   is_local_model:bool ->
   trigger:Compaction_trigger.t ->
   pre_compact_event option) ->
  unit
