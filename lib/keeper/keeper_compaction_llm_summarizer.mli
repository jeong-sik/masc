(** LLM-backed Keeper context compaction. The exact caller-supplied Runtime
    produces a structured {!compaction_plan}; unavailable providers and invalid
    plans fail explicitly as [None]. *)

(** A validated boundary compaction plan over a working set of
    [message_count] messages (masc#25099). Messages at index >= [keep_from]
    are kept verbatim; messages before the cut fold into the single [summary]
    prose block, except the [pinned_keep] exceptions which also survive
    verbatim. Invariants established by {!plan_of_json}: [0 <= keep_from <=
    message_count]; [pinned_keep] is sorted, duplicate-free, and every element
    is in [\[0, keep_from)]; at least one message is summarized ([keep_from >
    List.length pinned_keep]), so all-kept no-ops are invalid and [summary] is
    non-empty. Coverage gaps and duplicate bucket assignments — the dominant
    failure modes of the retired 3-way index-enumeration form — are
    unrepresentable. *)
type compaction_plan = private
  { summary : string
  ; keep_from : int
  ; pinned_keep : int list
  ; message_count : int
    (** Working-set size the plan was validated against. *)
  ; selected_runtime_id : string option
    (** Exact Runtime candidate that produced this plan. [None] only for a
        plan parsed directly through {!plan_of_json} before provider binding. *)
  }

(** Number of messages the plan folds into the summary:
    [keep_from - List.length pinned_keep]. Positive for every validated plan. *)
val summarized_count : compaction_plan -> int

(** [summarizer ~messages] returns [Some plan] when the LLM produced a valid
    plan over [messages], or [None] on any failure (provider error, empty
    or invalid structured response). Total and synchronous; the effect is
    hidden in the closure captured by {!make}. *)
type summarizer = messages:Agent_sdk.Types.message list -> compaction_plan option

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

(** Parse+validate a raw structured response into a plan over [message_count]
    messages. Exposed for tests. Returns [Error] with a reason on any
    structural violation ([keep_from] outside [\[0, message_count\]], a pinned
    index outside [\[0, keep_from)], an all-kept no-op plan, or a
    missing/empty summary). Duplicates inside [pinned_keep] denote the same
    set and collapse under set parsing. *)
val plan_of_json
  :  message_count:int
  -> Yojson.Safe.t
  -> (compaction_plan, string) result

(** [apply plan ~messages] rebuilds the working set from a validated [plan]:
    messages at index >= [keep_from] and the [pinned_keep] exceptions survive
    verbatim; everything else is replaced by a single assistant
    memory-summary message ([plan.summary]). Original message order is
    preserved; the summary is inserted at the position of the first
    summarized index. [plan] is assumed to have been validated against
    [List.length messages], so this is total. *)
val apply
  :  compaction_plan
  -> messages:Agent_sdk.Types.message list
  -> Agent_sdk.Types.message list

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
