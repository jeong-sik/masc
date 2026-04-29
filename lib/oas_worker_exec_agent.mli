(** Oas_worker_exec_agent — shared {!config} surface and agent
    assembly helpers.

    Owns the shared per-worker {!config} record + pure / defaulted
    preparation logic shared by both
    {!Oas_worker_exec.build} and
    {!Oas_worker_exec.resume_from_checkpoint}.
    {!Oas_worker_exec} remains the public facade and still
    performs the approval wiring and final
    [build_safe] / [Agent.resume] calls.

    Internal: \[guardrails_of_config\] (ToolName-list extraction
    used by builder) stays private — it is consumed only inside
    {!builder_without_approval}. *)

(** {1 Stop reason} *)

(** Why a worker run terminated. *)
type stop_reason =
  | Completed
  | TurnBudgetExhausted of { turns_used : int; limit : int }
  | MutationBoundaryReached of {
      turns_used : int;
      tool_name : string option;
    }

(** {1 Per-worker config} *)

type config = {
  name : string;
  provider_cfg : Llm_provider.Provider_config.t;
  provider : Oas.Provider.config;
  model_id : string;
  priority : Llm_provider.Request_priority.t option;
  system_prompt : string;
  tools : Oas.Tool.t list;
  runtime_mcp_policy :
    Llm_provider.Llm_transport.runtime_mcp_policy option;
  max_turns : int;
  max_idle_turns : int;
  stream_idle_timeout_s : float option;
  max_tokens : int;
  max_input_tokens : int option;
  max_cost_usd : float option;
  temperature : float;
  hooks : Oas.Hooks.hooks option;
  context_reducer : Oas.Context_reducer.t option;
  guardrails : Oas.Guardrails.t option;
  event_bus : Oas.Event_bus.t option;
  checkpoint_dir : string option;
  session_id : string option;
  description : string option;
  memory : Oas.Memory.t option;
  initial_messages : Oas.Types.message list;
  raw_trace : Oas.Raw_trace.t option;
  tool_retry_policy : Oas.Tool_retry_policy.t option;
  required_tool_satisfaction :
    Oas.Completion_contract.required_tool_satisfaction;
  contract : Oas.Risk_contract.t option;
  enable_thinking : bool option;
  transport : Masc_grpc_transport.t;
  allowed_paths : string list;
  checkpoint_sidecar : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
  compact_ratio : float option;
  context_injector : Oas.Hooks.context_injector option;
  context : Oas.Context.t option;
  slot_id : int option;
  approval : Oas.Hooks.approval_callback option;
  exit_condition : (int -> bool) option;
  exit_condition_result : (int -> stop_reason * string option) option;
  summarizer : (Oas.Types.message list -> string) option;
  cli_transport_overrides :
    Oas_worker_exec_transport.cli_transport_overrides option;
}
(** Per-worker configuration.  47 fields — concrete record because
    callers ({!Oas_worker_exec}, keeper workers) construct + tweak
    fields field-by-field at the dispatch site. *)

(** {1 Default config builder} *)

val default_config :
  name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  system_prompt:string ->
  tools:Oas.Tool.t list ->
  config
(** [default_config ~name ~provider_cfg ~system_prompt ~tools]
    returns a {!config} populated with sensible defaults for every
    field except the four required ones.  Caller mutates fields
    in place via record copy ([{ cfg with ... }]) before passing
    to {!builder_without_approval} or {!prepare_resume}. *)

(** {1 Builder (no approval)} *)

val builder_without_approval :
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  ?transport:Llm_provider.Llm_transport.t ->
  unit ->
  Oas.Builder.t
(** [builder_without_approval ~net ~config ?transport ()] builds an
    {!Oas.Builder.t} from [config] without wiring approval
    callbacks.  Approval wiring is the responsibility of the
    public facade ({!Oas_worker_exec}) which adds the approval
    callback before calling [Builder.build_safe]. *)

(** {1 Resume preparation} *)

type prepared_resume = {
  patched_checkpoint : Oas.Checkpoint.t;
  agent_config : Oas.Types.agent_config;
  options : Oas.Agent.options;
}
(** Output of {!prepare_resume}.  [patched_checkpoint] has
    [turn_count] and budget fields adjusted so that resume picks
    up where the previous run left off without re-counting
    consumed turns. *)

val prepare_resume :
  config:config -> checkpoint:Oas.Checkpoint.t -> prepared_resume
(** [prepare_resume ~config ~checkpoint] computes the patched
    checkpoint + agent_config + options for an
    [Agent.resume] call.  Pure — no side effects.  The patched
    checkpoint extends [config.max_turns] beyond the consumed
    [checkpoint.turn_count] so the resumed run gets a fresh
    turn budget instead of inheriting the exhausted one. *)
