(** LLM-backed keeper context compaction (RFC-0313-adjacent W2 +
    RFC-0327 B-0 provider-agnostic structured output).

    Opt-in per-keeper alternative to the deterministic extractive strategy
    chain. Requests a structured {!compaction_plan} from a librarian-lane
    provider that classifies each working-set message (by 0-based index) into
    kept / summarized / dropped, plus one [summary] prose block standing in
    for the summarized indices.

    RFC-0327 B-0: the plan is acquired via a hybrid dual path so the summarizer
    is not blocked on provider-native json_schema support. Providers that
    accept [response_format] json_schema use the native path; others
    (e.g. glm-coding) get the plan forced through a StructuredOutput tool call.
    Either way the same schema is parsed and a structurally invalid plan is
    re-fed to the model and retried up to [MASC_STRUCTURED_OUTPUT_MAX_RETRIES]
    (default 5).

    Fail-closed by construction: {!make} returns [None] (caller falls back to
    the deterministic chain) whenever the opt-in gate is off, the Eio context
    is unavailable, no direct-completion provider resolves, or the produced
    plan stays structurally invalid after retries. This mirrors
    {!Keeper_memory_llm_summary.make}; it never lies about effects — the
    provider call happens inside the fiber-local Eio context captured at
    construction, and the summarizer type stays synchronous+total. *)

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
    {!Llm_provider.Complete.complete}; overridable in tests. [?tools] is
    forwarded only on the RFC-0327 tool-call fallback path. *)
type complete_fn =
  sw:Eio.Switch.t ->
  net:Eio_context.eio_net ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?tools:Yojson.Safe.t list ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

(** [make ~runtime_id ~keeper_name ()] builds a summarizer bound to the
    librarian lane resolved from [runtime_id], or [None] if the opt-in gate is
    off / Eio context or a direct-completion provider is unavailable. The plan
    path (native json_schema or tool-call fallback) is chosen from the
    provider's capability and logged at info. The caller treats [None] as
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

(** {1 RFC-0327 B-0: provider-agnostic plan acquisition} *)

(** Which path a provider uses to return the plan: native
    [response_format] json_schema, or the StructuredOutput tool-call fallback
    used when the provider lacks native json_schema support (e.g. glm-coding). *)
type plan_path = Native_plan | Tool_fallback_plan

(** Tool name shared by the [tool_choice] target and the [Structured] schema
    the tool_use input is matched against. *)
val compaction_plan_tool_name : string

(** Parse+validate a response into a plan over [message_count] messages along
    [path]: the native path reads the response json; the tool-fallback path
    extracts the tool_use input whose name matches {!compaction_plan_tool_name}.
    Exposed for tests; the runtime picks the path from the provider's schema
    support. Returns [Error] on any structural violation or a missing tool_use
    block on the fallback path. *)
val plan_of_response
  :  message_count:int
  -> path:plan_path
  -> Agent_sdk.Types.api_response
  -> (compaction_plan, string) result
