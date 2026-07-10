(** LLM-backed keeper context compaction (RFC-0313-adjacent W2).

    Default compaction path, selected per keeper via [meta.compaction.mode]
    ([Llm] unless overridden). Requests a structured {!compaction_plan} from a
    librarian-lane provider that classifies each working-set message (by
    0-based index) into kept / summarized / dropped, plus one [summary] prose
    block standing in for the summarized indices.

    Fail-closed by construction: {!make} returns [None] (caller falls back to
    the deterministic chain) whenever the Eio context is unavailable, no
    schema-capable direct-completion provider resolves, or the produced plan
    is structurally invalid. This mirrors {!Keeper_memory_llm_summary.make};
    it never lies about effects — the provider call happens inside the
    fiber-local Eio context captured at construction, and the summarizer type
    stays synchronous+total. *)

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

(** [make ~runtime_id ~keeper_name ()] builds a summarizer bound to the
    librarian lane resolved from [runtime_id], or [None] if the Eio context
    or a schema-capable provider is unavailable. The caller treats [None] as
    "use the deterministic chain". [complete]/[timeout_sec] override the
    provider call and deadline (tests). *)
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
  (** Apply the compaction request policy while preserving the per-runtime
      temperature override from runtime.toml. *)
  val provider_for_plan
    :  runtime_id:string
    -> Llm_provider.Provider_config.t
    -> Llm_provider.Provider_config.t
end
