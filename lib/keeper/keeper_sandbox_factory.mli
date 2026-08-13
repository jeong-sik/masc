(** Turn-scoped factory for {!Keeper_turn_sandbox_runtime.t}.

    A single keeper turn may dispatch tool calls from different cwds,
    each implying a different [in_playground] state.  The factory
    evaluates {!Keeper_sandbox_runner.effective_sandbox_profile} once at
    construction, evaluates [in_playground] from the call-site [cwd] only for
    runtime workspace reuse, and memoizes one runtime per
    [(in_playground, network_mode)]
    so a Docker container is created at most once per compatible dispatch
    context within a turn.  The runtime can still execute from different cwd
    values via [Keeper_turn_sandbox_runtime.container_cwd_of_host].

    Background: pre-PR-3b, [keeper_tools_agent_core.make_tool_bundle] inspected
    [meta.sandbox_profile] eagerly at turn-start.  The factory still creates
    runtimes lazily at each call site, but freezes its construction meta so
    path resolution and dispatch use one sandbox profile for the whole turn.
    Registry reconciliation takes effect on the next turn; consulting it
    mid-turn can otherwise route a Docker-scoped cwd through Local dispatch.
    The declared sandbox profile remains the execution contract: [Local]
    resolves to [Local_profile] even when DockerPlayground is enabled.

    The dependency on {!Keeper_sandbox_docker} stays acyclic:
    [keeper_sandbox_docker] only consumes [Keeper_turn_sandbox_runtime.t]
    as a parameter and never constructs one itself. *)

type resolve_result =
  | Runtime of Keeper_turn_sandbox_runtime.t
  | No_factory
  | Local_profile

type t

type routing_refusal =
  | Invalid_requested_boundary of
      Keeper_runtime_contract.Sandbox_routing.invalid_boundary
  | Invalid_effective_boundary of
      Keeper_runtime_contract.Sandbox_routing.invalid_boundary
  | Admission_violation of
      { violation : Keeper_runtime_contract.Sandbox_routing.violation
      ; evidence : Keeper_runtime_contract.Sandbox_routing.evidence
      }
  | Receipt_violation of
      { violation : Keeper_runtime_contract.Sandbox_routing.violation
      ; evidence : Keeper_runtime_contract.Sandbox_routing.evidence
      }
  | Invalid_receipt_boundary of
      Keeper_runtime_contract.Sandbox_routing.invalid_boundary
  | Invalid_receipt_detail of string

val routing_refusal_to_string : routing_refusal -> string
val routing_refusal_evidence : routing_refusal -> Keeper_runtime_contract.Sandbox_routing.evidence option

val create :
  ?default_network_override:Keeper_types_profile_sandbox.network_mode ->
  ?requested_sandbox_profile:Keeper_types_profile_sandbox.sandbox_profile ->
  ?requested_network_mode:Keeper_types_profile_sandbox.network_mode ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?turn_id:int ->
  unit ->
  t
(** Create an empty factory and freeze both the requested and actual effective
    route. [requested_*] must come from the persisted keeper profile; callers
    that omit them use [meta] as both stages. [default_network_override], when
    supplied, participates in the effective stage and is applied to every
    runtime created via {!resolve}. *)

val routing_admission : t -> (unit, routing_refusal) result
(** Typed pre-effect admission. A config/effective mismatch is rejected before
    any Docker runtime or tool effect can start. *)

val routing_evidence_for_receipt :
  t ->
  (Keeper_runtime_contract.Sandbox_routing.evidence, routing_refusal) result
(** Observe the factory-frozen effective route at receipt assembly. Absence or
    inconsistency remains a typed refusal; it is never replaced with [meta]. *)

val resolve :
  t ->
  cwd:string ->
  resolve_result
(** Returns [Runtime runtime] when the factory-frozen effective route yields
    [Docker]. [in_playground] is
    derived from [cwd] vs the keeper's playground root for runtime workspace
    reuse only. Memoizes per [(in_playground, network_mode, host_root, image)]
    so subsequent compatible calls reuse the same container without crossing
    sandbox-profile or image drift. Registry changes are observed by the next
    turn's factory, never midway through the current turn.

    [Local_profile] is returned when the effective sandbox profile is [Local].
    [No_factory] is only produced by {!resolve_opt}. *)

val resolve_opt :
  t option ->
  cwd:string ->
  resolve_result
(** [No_factory] when [t option] is [None]. Otherwise delegates to {!resolve}.
    Lets call sites distinguish "factory missing" from "Local profile". *)

val container_cwd_of_host_opt : t option -> host_cwd:string -> string option
(** Pure Docker CWD projection for response shaping. Unlike {!resolve_opt},
    this does not create or memoize a turn sandbox runtime. *)

val cleanup : t -> unit
(** Tears down every runtime created via {!resolve}.  Idempotent. *)
