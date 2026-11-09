(** Keeper_tools_agent_core — Wrap keeper tools as [Agent_core.Tool.t] for [Agent.run].

    Bridges [Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome] dispatch
    to [Agent_core.Tool.t list] via [Tool_bridge.agent_core_tool_of_masc]. Tool
    execution reads the current context from [ctx_snapshot]
    (immutable), enabling [Agent.run] to manage messages while
    keeper tools access the working context for status/metrics.

    @since Phase 4 — Keeper → Agent.run() migration *)

(** Bundle returned by [make_tool_bundle]: the [Agent_core.Tool.t list]
    plus a [cleanup] thunk that releases the per-turn sandbox
    runtimes. *)
type terminal_effect_failure =
  { failure_class : Tool_result.tool_failure_class
  ; effect_disposition : Tool_result.failure_effect_disposition
  ; detail : Keeper_terminal_effect_detail.t
  }

type terminal_effect_state =
  | Terminal_effect_open
      (** No tool has requested a turn boundary. *)
  | Deferred_tool_result
      (** A normal tool transition deferred; it is not a Gate external effect. *)
  | External_effect_deferred
      (** Gate deferred an external effect and will emit a durable resolution. *)
  | Terminal_effect_completed of Keeper_tool_execution.terminal_effect_receipt
  | Terminal_effect_failed of terminal_effect_failure

(** What a Keeper is attached to, before the turn decides how to show it.

    The bundle takes this rather than a finished listing because deciding what
    to hold back is its job: an attached tool is held by default, and a
    built-in is held when its own tool file declares it, and those two have to
    end up in one listing. *)
type attached_surface =
  { offered : Keeper_identity_tools.offered_tool list
  ; agent_cell : Agent_core.Agent.t option ref
        (** Filled by [Runtime_agent.run] at agent creation, before any tool
            of that agent can run. Travels with [offered] because tools
            without a cell are tools that can be named and never called. *)
  ; history : Agent_core.Types.message list
        (** The conversation this turn continues, read to find which held
            tools it has already run. *)
  ; load_receipts : Keeper_tool_load_receipts.restored
        (** This turn's successful-load state, restored into the same Context
            that the running agent checkpoints. *)
  ; keeper_turn_id : int
        (** The absolute Keeper-lane turn this surface is built for. Bounds
            how long an uncalled load stays placed
            ({!Keeper_tool_load_receipts.create}). *)
  }

(** Whether this turn placed a listing tool on the Agent Core surface, and if
    so which built-ins it left out to do so.

    One value rather than a flag beside a list: a turn with no listing has
    nothing behind it, and two fields let that state be written down. Both are
    read together at both call sites anyway.

    Reported rather than derived. "Is anything attached" stopped answering the
    first question once built-ins declared their own loading, and reading
    either back off the surface would make the projection check expect exactly
    what is there -- which is not a check. A listing that went missing, or a
    tool that left the request for some other reason, is what it has to catch. *)
type listing_placement =
  | No_listing
  | Listing of
      { deferred_builtin_names : string list
        (** The built-ins this surface actually left out. A tool declaring
            [defer_loading = true] is not enough to be here: one this
            conversation has run is placed with its schema again, so a declared
            tool the Keeper uses is on the surface after all. *)
      }

type image_admission = Image_input_admitted | Image_input_unavailable

val descriptor_admitted : image_admission -> Keeper_tool_descriptor.t -> bool
(** One typed descriptor rule for constructing and independently checking a
    candidate's model surface. Only the native image reader requires admitted
    image input; delegated analysis retains its existing availability. *)

type model_tool_surface = private
  { image_admission : image_admission
  ; tools : Agent_core.Tool.t list
  ; agent_core_tools : Agent_core.Tool.t list
  ; on_demand_tool_names : string list
  ; result_bounds : (string * int) list
  ; listing : listing_placement
  }
(** One selected materialized runtime's model view. The admission is captured
    from [Runtime_agent.runtime_accepts_image_input], without rereading a
    mutable runtime table. Handler, sandbox and effect state stay bundle-owned. *)

val assemble_model_tool_surface :
  image_admission:image_admission ->
  tools:Agent_core.Tool.t list ->
  agent_core_tools:Agent_core.Tool.t list ->
  on_demand_tool_names:string list ->
  result_bounds:(string * int) list ->
  listing:listing_placement ->
  model_tool_surface
(** Internal bundle projection data assembly. This constructor grants no tool
    authority and is not an operator policy setting. The bundle supplies its
    already captured admission and the views selected under that same value.
    The caller owns consistency: nothing here checks that [tools] matches
    [image_admission] (a native image reader may accompany
    [Image_input_unavailable], and [Image_input_admitted] may arrive without
    one), so only the bundle's capture path — which derives both from the
    same runtime observation — should build production surfaces. *)

type model_tool_projection =
  runtime:Runtime_instance.t -> carried:Agent_core.Tool.t list -> model_tool_surface

type tool_bundle =
  { tools : Agent_core.Tool.t list
    (** Every tool this turn can run, attached-service tools included as
        schemas. The official-client lanes take this: they cannot widen a
        running turn, so a listing would name tools they can never make
        callable. *)
  ; agent_core_tools : Agent_core.Tool.t list
    (** The same turn for the Agent Core lane, with the attached-service
        schemas replaced by one listing tool that hands them over on request
        (RFC-attached-service-tool-scoping). Only this lane can widen a
        running turn's tool set. *)
  ; on_demand_tool_names : string list
    (** The names in [tools] an official client loads on demand: every
        built-in whose declaration says [defer_loading = true] and every
        attached-service tool. The rest are loaded upfront. The Agent Core
        lane does not read it; its own listing already holds these back. *)
  ; result_bounds : (string * int) list
    (** For each tool in [tools] whose result MASC bounds, the byte ceiling it
        is bounded to: a built-in's result crosses its descriptor's
        {!Tool_output.model_projection}, and on an official-client lane that
        projection is the descriptor's own, so its inline ceiling is the bound.
        Attached-service tools are absent: their results reach the wire as the
        service returned them. The Agent Core lane does not read it. *)
  ; listing : listing_placement
        (** What this turn put behind the listing, if it placed one. *)
  ; project_for_runtime : model_tool_projection
        (** Construct the current candidate's schemas and deferred loader from
            the same admitted set. [carried] is the preceding Agent Core view;
            only canonical entries admitted now can be carried. Outstanding
            loads retain their original receipts while withheld from a view.
            Projection does not execute tools or replace their shared state.
            Callers must use the captured admission for their execution hook.
            The unprojected fields above remain the configured turn surface. *)
  ; cleanup : unit -> unit
  ; terminal_effect_state : unit -> terminal_effect_state
  ; gate_replay_inputs : Keeper_gate_replay.resolution_input list
  ; turn_sandbox_factory : Keeper_sandbox_factory.t option
        (** The factory the bundle's tools resolve through, handed back so
            turn setup can reach the same endpoint the turn's own calls will
            — paste delivery is the consumer: a microvm guest may only be
            started by the turn that owns its lifecycle
            ([microvm_remote_requires_turn_sandbox_factory]). *)
  }

(** Per-keeper tool usage view from [Keeper_registry]. *)
val tool_usage_for_keeper : string -> (string * Keeper_types.tool_call_entry) list

(** Record an internal keeper tool call in the telemetry registry. *)
val record_keeper_internal_tool_call
  :  tool_name:string
  -> disposition:('completed, 'deferred, 'failed) Tool_result.disposition
  -> duration_ms:int
  -> unit

(* Handlers moved to [Keeper_tools_agent_core_handler] — see
   keeper_tools_agent_core_handler.mli for [make_keeper_tool_handler],
   [make_tool_bundle], and [make_tools]. *)


(** Build the per-tool handler closure used by both internal and
    alias tool entries. The closure dispatches via
    [execute_keeper_tool_call_with_outcome] using [~name] as the
    INTERNAL tool name (telemetry SSOT). [~input_schema] is the
    internal tool schema used for pre-execution validation. Public aliases
    validate their LLM-facing payload before translation to the internal
    payload. *)

(** Build the keeper's full [tool_bundle]: internal tools +
    alias-registered (public name) tools that translate input to
    internal payloads. The cleanup thunk releases per-turn sandbox
    runtimes (Docker case). *)

(** Convenience over [make_tool_bundle] returning only [.tools]. *)
