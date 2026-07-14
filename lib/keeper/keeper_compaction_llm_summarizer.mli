(** LLM-backed Keeper context compaction. The exact caller-supplied Runtime
    produces a structured {!compaction_plan}; unavailable providers and invalid
    plans fail explicitly as [None]. *)

(** A validated compaction plan over a working set of [n] messages. Every
    index in [kept]/[summarized]/[dropped] is in [\[0, n)], the three sets are
    pairwise disjoint, and together they cover every index exactly once. For
    non-empty inputs, at least one [kept] or [summarized] index is required so
    applying the plan cannot erase the entire working set. *)
type compaction_plan = private
  { summary : string
  ; kept : int list
  ; summarized : int list
  ; dropped : int list
  }

(** [summarizer ~messages] returns [Some plan] when the LLM produced a valid
    plan over [messages], or [None] on any failure (timeout, http error, empty
    or invalid structured response). Total and synchronous; the effect is
    hidden in the closure captured by {!make}. *)
type summarizer = messages:Agent_sdk.Types.message list -> compaction_plan option

(** The low-level provider completion the summarizer drives. Defaulted to
    {!Llm_provider.Complete.complete}; overridable in tests. *)
type complete_fn =
  sw:Eio.Switch.t ->
  net:Eio_context.eio_net ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

(** [make ~runtime_id ~keeper_name ()] resolves [runtime_id] as a Runtime or
    Runtime Lane. A Runtime contributes its exact provider config; a Lane tries
    its configured Runtime candidates in declared order until one returns a
    valid plan. Missing, ineligible, and failed candidates are logged with
    their Runtime id. No default Runtime is substituted. [complete]/
    [timeout_sec] override the call in tests. *)
val make
  :  ?complete:complete_fn
  -> ?timeout_sec:float
  -> runtime_id:string
  -> keeper_name:string
  -> unit
  -> summarizer option

(** Parse+validate a raw structured response into a plan over [message_count]
    messages. Exposed for tests. Returns [Error] with a reason on any
    structural violation (out-of-range / negative / duplicate / non-covering
    indices, empty output for a non-empty working set, or a missing/empty
    summary). *)
val plan_of_json
  :  message_count:int
  -> Yojson.Safe.t
  -> (compaction_plan, string) result

(** [apply plan ~messages] rebuilds the working set from a validated [plan]:
    [kept] indices survive verbatim, the [summarized] indices are replaced by a
    single assistant memory-summary message ([plan.summary]), and [dropped]
    indices are removed. Original message order is preserved; the summary is
    inserted at the position of the first summarized index. [plan] is assumed
    to have been validated against [List.length messages] (it partitions the
    index space), so this is total. *)
val apply
  :  compaction_plan
  -> messages:Agent_sdk.Types.message list
  -> Agent_sdk.Types.message list

module For_testing : sig
  (** Apply the compaction request policy while preserving the input provider
      config's exact temperature, including omission. *)
  val provider_for_plan
    :  Llm_provider.Provider_config.t
    -> Llm_provider.Provider_config.t

  (** Eligible Runtime ids for a Runtime/Lane assignment, in exact declaration
      order. Provider configs are intentionally not exposed. *)
  val candidate_runtime_ids_for_assignment
    :  keeper_name:string
    -> runtime_id:string
    -> string list option
end
