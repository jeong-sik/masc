(** Keeper_compact_policy — compaction gate and strategy application.

    Decides whether compaction should run based on ratio/message/token
    gates and cooldown, then applies OAS strategies + persona fold.

    Extracted from Keeper_exec_context as part of #4955 god-file split. *)

(** Fraction of context window at which compaction is treated as an
    emergency, bypassing the continuity-reflection cooldown gate. *)
val emergency_compact_ratio_threshold : float

(** Tool-heavy compaction gate: minimum message count before the
    [tool_heavy] gate becomes eligible. *)
val tool_heavy_msg_threshold : int

(** Tool-heavy compaction gate: minimum context ratio before the
    [tool_heavy] gate becomes eligible. *)
val tool_heavy_ratio_floor : float

(** Project [meta] to its [(ratio_gate, message_gate, token_gate)]
    tuple. *)
val compaction_policy_of_keeper :
  Keeper_types.keeper_meta -> float * int * int

(** [compact_if_needed ~meta ~now_ts ctx] evaluates the compaction
    gates and either returns [ctx] unchanged or applies the OAS
    strategy chain plus the keeper-private fold reducer.

    Return triple:
    - the (possibly compacted) working context;
    - [Some reason] when compaction was applied, [None] otherwise;
    - a status string of the form
      [{"applied:<reason>", "blocked:below_thresholds",
       "skipped:continuity_reflection(<elapsed>s<<cooldown>s)"}]. *)
val compact_if_needed :
  meta:Keeper_types.keeper_meta ->
  now_ts:float ->
  Keeper_context_core.working_context ->
  Keeper_context_core.working_context * string option * string
