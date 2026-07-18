(** LLM-backed Keeper context compaction. The exact caller-supplied Runtime
    produces a structured {!compaction_plan}; unavailable providers and invalid
    plans fail explicitly as [None]. *)

(** A validated immutable plan bound to the exact source units from which it
    was parsed. Protected units cannot be named by a provider decision, and a
    plan cannot be applied to a different source. *)
type compaction_plan

(** [summarizer ~units] returns [Some plan] when the LLM produced a valid plan
    over [units], or [None] on any failure (provider error, empty
    or invalid structured response). Total and synchronous; the effect is
    hidden in the closure captured by {!make}. *)
type summarizer =
  units:Keeper_compaction_unit.closed_unit list -> compaction_plan option

(** The low-level provider completion the summarizer drives. Defaulted to
    {!Llm_provider.Complete.complete}; overridable in tests. *)
type complete_fn = Keeper_provider_subcall.complete_fn

(** [make ~runtime_ids ~keeper_name ()] resolves each id in [runtime_ids],
    most-preferred first, exactly as a single {!candidate_runtime_ids_for_assignment}
    would: a Runtime contributes its exact provider config, a Lane tries its
    configured Runtime candidates in declared order. Every eligible candidate
    across every seed id is tried, seed order first and then per-seed lane
    order, with candidates that resolve to the same Runtime id collapsed to
    their first (highest-priority) occurrence. Missing, ineligible, and failed
    candidates are logged with their Runtime id. No default Runtime is
    substituted. [complete] overrides the Provider boundary in tests.

    The compaction owner imposes no wall-clock deadline. Cancellation belongs
    to the owning Keeper lane or to the Provider transport boundary. *)
val make
  :  ?complete:complete_fn
  -> runtime_ids:string list
  -> keeper_name:string
  -> unit
  -> summarizer option

(** Whether [units] contains at least one structurally eligible ordinary
    Assistant text message. System, User, Tool, metadata-bearing, non-text,
    closed-tool-cycle, and open-suffix units are never eligible. *)
val has_eligible_units : Keeper_compaction_unit.closed_unit list -> bool

(** Parse and validate a raw structured response against the exact [units] and
    bind the non-empty [runtime_id] that produced it. Every eligible source
    index must appear exactly once; every other index is rejected. Unknown
    fields, duplicate fields, invalid action/summary pairs, all-kept no-ops,
    and output-erasing plans fail explicitly. *)
val plan_of_json
  :  runtime_id:string
  -> units:Keeper_compaction_unit.closed_unit list
  -> Yojson.Safe.t
  -> (compaction_plan, string) result

val apply : compaction_plan -> Agent_sdk.Types.message list
val selected_runtime_id : compaction_plan -> string
val summarized_indices : compaction_plan -> int list
val dropped_indices : compaction_plan -> int list
val has_changes : compaction_plan -> bool

module For_testing : sig
  val with_make_override
    :  (runtime_ids:string list -> keeper_name:string -> unit -> summarizer option)
    -> (unit -> 'a)
    -> 'a

  (** Apply the compaction request policy while preserving the input provider
      config's exact temperature, including omission. *)
  val provider_for_plan
    :  Llm_provider.Provider_config.t
    -> Llm_provider.Provider_config.t

  (** Eligible Runtime ids for a single Runtime/Lane assignment, in exact
      declaration order. Provider configs are intentionally not exposed. *)
  val candidate_runtime_ids_for_assignment
    :  keeper_name:string
    -> runtime_id:string
    -> string list option
  (** Exact provider request constructed from eligible units. Exposed only to
      prove that protected source content never crosses the provider boundary. *)
  val messages_for_plan
    :  units:Keeper_compaction_unit.closed_unit list
    -> Agent_sdk.Types.message list

  (** Eligible Runtime ids across a priority-ordered list of seed
      Runtime/Lane assignments, in exact seed-then-declaration order, with
      cross-seed duplicates collapsed to their first occurrence. Unlike
      {!candidate_runtime_ids_for_assignment}, this never returns [None]: a
      seed that fails to resolve simply contributes no candidates. *)
  val candidate_runtime_ids_for_assignments
    :  keeper_name:string
    -> runtime_ids:string list
    -> string list
end
