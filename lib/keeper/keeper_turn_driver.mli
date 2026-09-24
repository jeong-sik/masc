(** Keeper_turn_driver — MASC named-runtime and model-label execution entry points.

    Public API for running AGENT_CORE agents through MASC-managed named runtime
    profiles ([run_named]) or explicit model label ([run_model_by_label]),
    with optional MASC tool bridging variants.

    The facade intentionally exposes only the logical keeper entry points and
    typed MASC/AGENT_CORE error helpers. Provider/model-shaped AGENT_CORE runner helpers stay
    behind lower-level boundary modules.

    Owns one Keeper turn over the MASC runtime boundary. *)

(** {1 MASC/AGENT_CORE structured errors}

    Re-exported from {!Keeper_internal_error}. The manifest aliases keep the
    facade's public types identical to the internal-error SSOT instead of
    copying fresh nominal types into this interface. *)

(* [struct include ... end] strengthens every type to an alias of the SSOT's,
   which is what the hand-written [with type] list did one type at a time. It
   is written this way because [fenced_cause] and [masc_internal_error] are
   one recursive group (RFC-0454 D1): a [with type] on either member sees the
   other as the copy this include made, so the manifest is refused. *)
include module type of struct
  include Keeper_internal_error
end

(** {1 Turn pipeline records} *)

(** {1 Named runtime execution} *)

type output_contract = Provider_default | Tool_verdict
(** [Tool_verdict] leaves final prose unconstrained: API response_format is
    cleared and official clients use their ordinary tool-call channel. It does
    not suppress arbitrary provider transforms or validate tool arguments; the
    caller owns the typed verdict protocol. *)


type deferred_runtime_lane = private
  { assignment_id : string
  ; failed_runtime_id : string
  ; next_runtime_id : string
  ; later_runtime_ids : string list
  ; failure : Agent_core.Error.t
  }

(** The candidate error a runtime walk returned as the lane's error, with the
    candidate that produced it. [origin_runtime_id] can differ from the
    candidate the walk ended on: on an exhausted lane a typed context overflow
    observed on an earlier candidate outranks a later recoverable error, and
    the lane returns that overflow. Reported through
    [on_runtime_lane_terminal_error] on every walk that returns a candidate's
    error; a lane with no candidates returns its own error and reports
    nothing. *)
type lane_terminal_error =
  { origin_runtime_id : string
  ; origin_attempt : int
  ; lane_error : Agent_core.Error.t
  ; checkpoint_after : Agent_core.Checkpoint.t option
  }

val deferred_runtime_ids : deferred_runtime_lane -> string list

(** How the lane that dispatched a turn continues after the turn fails
    (RFC last-path-resumes-after-progress §3.5).
    - [Resume_operation_checkpoint]: the chat lane. The named operation resumes
      from its latest saved checkpoint, so tool results it saved are not run
      again. It carries the operation because only a lane that has one can
      resume: the heartbeat lane runs no chat operation, and a cycle that
      resumed a path this way would never end (§3.5). The driver reports the
      operation when it defers one to the path it failed on.
    - [Restart_cycle]: the heartbeat lane. The next cycle is a new turn. *)
type failure_continuation =
  | Resume_operation_checkpoint of { operation_id : Keeper_operation_id.t }
  | Restart_cycle

(** Where a lane walk hands the suffix a failed turn defers to, and how that
    lane continues. A walk without one defers nothing. *)
type runtime_retry_deferral =
  { continuation : failure_continuation
  ; on_deferred : deferred_runtime_lane -> unit
  }
val quota_ordered_deferred_runtime_lane :
  now:float -> deferred_runtime_lane -> deferred_runtime_lane
(** Apply active quota-window ordering to a frozen deferred suffix while
    preserving its assignment and failure evidence. Call once before building
    pre-dispatch execution so prompt shaping and dispatch consume the same
    selected runtime. *)

(** Whether one runtime path is resting at a given instant
    (RFC-provider-path-rest §3.3). Read from the 429 candidate observation and
    the quota window; a failed attempt is no rest (RFC-0458 §3.4).
    [walk_promotes_at_release] is [true] when the walk order moves the path
    ahead of the paths still told to rest at [release_at]: every rest on it was
    stated by the provider and not cut by the cap. A failed attempt the path
    also holds keeps it behind the paths with no evidence. An id the runtime
    table cannot resolve is serving. *)
type path_rest =
  | Path_serving
  | Path_resting of
      { release_at : float
      ; walk_promotes_at_release : bool
      }

val path_rest : now:float -> string -> path_rest

(** What a walk dispatches first. [Walk_head_serving]: the head in walk order
    is not resting and takes the input. [Walk_waits_until]: the head rests; the
    wait ends at the head's release, or at an earlier release of a later path
    the walk order promotes at that moment, and [resting_runtime_id] owns that
    release. *)
type walk_rest =
  | Walk_head_serving of { runtime_id : string }
  | Walk_waits_until of
      { release_at : float
      ; resting_runtime_id : string
      }

(** Who a walk runs for (RFC-0458 §3.4 rule 5).
    [Fleet_keeper_turn recorder]: a fleet Keeper's turn. It comes back every
    cycle, so a failure it sees names it as the recorder.
    [One_shot_walk]: a walk no cycle repeats, such as a completion review. It
    records no failed-attempt mark (timeout, 5xx, 529, network): a mark naming it
    would have no one to retry it, and would hold the candidate behind for
    every Keeper until something else dispatched it and got an answer. Its
    429 and 402 evidence is recorded as any walk's. An answer it receives
    still clears the candidate's evidence, whoever recorded it. *)
type walk_owner =
  | Fleet_keeper_turn of Runtime_candidate_backpressure.recorder
  | One_shot_walk

(** Whose walk orders the lane (RFC-0458 §3.4, 2026-09-23).
    [Fresh_walk_by recorder]: a fleet Keeper's turn without a deferred
    suffix. A failed attempt that Keeper recorded does not demote its
    candidate, so its next cycle dispatches the first such candidate again
    (normally the head) and the answer renews or clears the mark; without this
    the fallback kept answering and the head never came back until restart
    (#38174). Failed attempts other Keepers recorded still demote.
    [Every_mark_demotes]: a failed turn's deferred suffix, a rotation inside a
    walk, or a one-shot walk. Every failed attempt demotes. *)
type walk_start =
  | Fresh_walk_by of Runtime_candidate_backpressure.recorder
  | Every_mark_demotes

(** A deferred suffix in the order the next turn walks it. *)
val deferred_lane_rest : now:float -> deferred_runtime_lane -> walk_rest

(** The candidates a fresh walk of an assignment dispatches, in [order]: the
    lane [declared], then quota and backpressure demotion, which moves a
    resting or exhausted candidate behind its siblings and excludes none.
    Nothing else reorders it: a success leaves no preference behind, so the
    cycle after a failover starts from the declared head again. The walk may
    still replace the head for an input modality it cannot take (RFC-0265);
    a turn that failed and deferred its input walks the suffix it deferred
    instead: the candidates after the one that failed, or, for a chat
    operation whose last candidate failed after saving tool results, that
    candidate again. *)
type walk_order =
  { lane_id : string
  ; declared : string list
  ; order : string list
  }

(** Why a fresh walk would not dispatch the assignment at all, as
    [run_named] refuses it. *)
type assignment_refusal =
  | Assignment_missing  (** The id names no configured lane or runtime. *)
  | Catalog_unavailable of Runtime.missing_catalog_model
      (** The configured identity has no capability catalog entry. *)

val assignment_refusal_to_string : assignment_refusal -> string
val assignment_walk_order :
  now:float -> walk:walk_start -> string -> (walk_order, assignment_refusal) result

(** A fresh walk of an assignment, ordered as a turn without a deferred suffix
    orders it: {!assignment_walk_order}'s head and its rest. *)
val assignment_walk_rest : now:float -> string -> walk_rest

(** The next dispatch after a failed turn (RFC-provider-path-rest §3.1),
    shared by the heartbeat cycle and the chat lane's deferred retry.
    A deferred suffix dispatches now when its walk head serves, else waits as {!deferred_lane_rest} says.
    Without a suffix a rate limit or quota waits for the later of the failed
    path's rest and {!assignment_walk_rest}; [waiting_on] then names the
    assignment or the resting head. Every other failure without a suffix is
    [None]: no provider wait. *)
type next_dispatch =
  | Dispatch_now of { runtime_id : string }
  | Wait_until of
      { release_at : float
      ; waiting_on : string
      }

val next_dispatch_after_failure :
  now:float ->
  route:Keeper_runtime_failure_route.route ->
  assignment_id:string ->
  deferred_runtime_lane option ->
  next_dispatch option

val equal_deferred_runtime_lane :
  deferred_runtime_lane -> deferred_runtime_lane -> bool

val restore_deferred_runtime_lane :
  assignment_id:string ->
  failed_runtime_id:string ->
  next_runtime_id:string ->
  later_runtime_ids:string list ->
  failure:Agent_core.Error.t ->
  deferred_runtime_lane
(** Rebuild a lane suffix from the strict durable checkpoint owned by MASC.
    Runtime ids remain frozen; no current runtime-table lookup or compatibility
    fallback occurs at this boundary. *)

type named_run_result =
  { run_result : Runtime_agent.run_result
  ; official_client_settlement : Keeper_official_client_session_store.t option
  ; selected_runtime_id : string
  ; selected_max_context : int
  ; checkpoint_owner : Runtime_execution.checkpoint_owner
  ; lane_attempt_index : int
    (** Position of the winning candidate in this turn's lane walk
        ([attempt_runtime_candidates]'s [idx], 0-based). 0 means the turn
        settled on the first candidate; a later index means the lane
        rotated past one or more failed candidates before landing here.
        This is the truth source for the execution receipt's
        [runtime_fallback_applied] / [runtime_outcome]. *)
  }

type runtime_attempt =
  { routing_run_id : string
  ; runtime_id : string
  ; lane_attempt_index : int
  ; checkpoint_owner : Runtime_execution.checkpoint_owner
  }
(** Exact materialized candidate selected immediately before dispatch.
    [routing_run_id] identifies one lane walk, including reentry into the same
    Keeper turn. Together with [lane_attempt_index] it joins raw response usage
    to routed/completed/failed manifest rows. Lane
    assignment ids and later runtime-table lookups are not attempt authority. *)

type attempt_input =
  { attempt_goal_blocks : Agent_core.Types.content_block list option
  ; attempt_initial_messages : Agent_core.Types.message list
  ; attempt_agent_core_checkpoint : Agent_core.Checkpoint.t option
  ; attempt_replay_prefix_projection : Keeper_replay_prefix.projection
  }
(** One candidate's dispatch view of the turn input. RFC-0265 media degrade
    projects the goal, the pre-turn history and the resumed checkpoint against
    the input capabilities of the runtime being dispatched; the caller's
    canonical history is never rewritten, and
    [attempt_replay_prefix_projection] restores a checkpoint taken on the
    projected prefix back onto it. Decided per attempt inside the lane walk,
    so two candidates with different capabilities receive different views of
    the same turn. *)

val run_named :
  ?input_policy:Keeper_input_policy.t ->
  runtime_id:string ->
  ?keeper_name:string ->
  walk_owner:walk_owner ->
  ?pre_tool_rejects:Keeper_official_client_host.rejected_tool_call list ref ->
  base_path:string ->
  goal:string ->
  ?goal_blocks:Agent_core.Types.content_block list ->
  ?session_id:string ->
  system_prompt:string ->
  ?tools:Agent_core.Tool.t list ->
  agent_core_tools:Agent_core.Tool.t list ->
  ?tool_requirement:Keeper_required_tools.t ->
  ?required_native_posture:Runtime_native_tools.posture ->
  ?initial_messages:Agent_core.Types.message list ->
  ?model_input_projection:Agent_core.Agent.model_input_projection ->
  ?recovery_view:Keeper_recovery_transmission.t ->
  ?temperature:float ->
  ?accept:(Agent_core.Types.api_response -> bool) ->
  ?hooks:Agent_core.Hooks.hooks ->
  ?approval_gate:Keeper_tool_approval_gate.t ->
  ?raw_trace:Agent_core.Raw_trace.t ->
  ?on_event:(Agent_core.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Agent_core.Agent.t option ref ->
  ?transport:Masc_grpc_transport.t ->
  ?checkpoint_sidecar:Yojson.Safe.t ->
  ?cache_system_prompt:bool ->
  ?yield_on_tool:bool ->
  ?checkpoint_sink:Agent_core.Agent.checkpoint_sink ->
  ?context_injector:Agent_core.Hooks.context_injector ->
  ?context:Agent_core.Context.t ->
  ?terminal_effect_state:(unit -> Keeper_tools_agent_core.terminal_effect_state) ->
  ?enable_thinking:bool ->
  ?cooperative_yield_probe:Runtime_agent.cooperative_yield_probe ->
  ?person_queued_probe:(unit -> bool) ->
  ?agent_core_checkpoint:Agent_core.Checkpoint.t ->
  ?continue_from_checkpoint:bool ->
  ?trace_link:string * string ->
  ?event_bus:Agent_core.Event_bus.t ->
  ?on_runtime_observation:(Runtime_observation.runtime_observation -> unit) ->
  ?on_request_wire_observation:
    (runtime_id:string ->
     body_bytes:int ->
     serialized:Llm_provider.Request_wire_observer.observation option ->
     unit) ->
  ?on_request_attribution:
    (runtime_id:string ->
     tools:Agent_core.Tool.t list ->
     transmitted:Keeper_official_client_host.transmitted_model_input ->
     unit) ->
  ?official_client_continuation:Keeper_semantic_execution.official_client_checkpoint ->
  ?official_client_original_turn:Keeper_semantic_execution.official_client_checkpoint ->
  ?official_task_reference:Keeper_official_task_reference.t ->
  ?on_official_client_tool_boundary:
    (unit -> (Keeper_official_client_host.host_stop option, Agent_core.Error.t) result) ->
  ?on_official_client_result_handoff:
    (runtime_id:string ->
     invocation:Agent_core.Tool_contract.Invocation.t ->
     content:string ->
       unit) ->
  ?on_official_client_native_action:
    (runtime_id:string -> official_turn:int ->
     identity:Runtime_native_tools.action_identity -> tool_name:string -> unit) ->
  ?on_model_input_window_observation:
    (measurement:Turn_record.model_input_measurement
     -> Runtime_model_input_tail_window.window_observation
     -> unit) ->
  ?on_response_observed_model_input:
    (Turn_record.response_observed_model_input -> unit) ->
  ?carried_front_seed:(unit -> Keeper_carried_front.seed_read) ->
  ?runtime_manifest_context:Keeper_runtime_manifest.turn_context ->
  ?runtime_manifest_append:(Keeper_runtime_manifest.t -> unit) ->
  ?deferred_runtime_lane:deferred_runtime_lane ->
  ?on_runtime_attempt:(runtime_attempt -> unit) ->
  ?runtime_retry_deferral:runtime_retry_deferral ->
  ?checkpoint_progress:
    Keeper_turn_driver_try_provider.checkpoint_progress Atomic.t ->
  ?on_runtime_attempt_error:
    (runtime_id:string ->
    attempt:int ->
    dispatch:Keeper_attempt_dispatch.t ->
    Agent_core.Error.t ->
    unit) ->
  ?on_runtime_lane_terminal_error:(lane_terminal_error -> unit) ->
  ?on_deferred_runtime_consumed:(unit -> unit) ->
  ?output_contract:output_contract ->
  ?provider_config_transform:
    (Llm_provider.Provider_config.t ->
    (Llm_provider.Provider_config.t, Agent_core.Error.t) result) ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (named_run_result, Agent_core.Error.t) result
(** Run a single [Agent.run] call with MASC-driven runtime model fallback.
    MASC drives the runtime FSM directly: resolves runtime providers,
    resolves each candidate's model temperature before trying it with AGENT_CORE, and
    uses [Runtime_fsm.decide] on failure.
    The runtime loop runs inside a capacity-managed queue permit.

    [on_runtime_attempt_error] observes every typed candidate failure after
    its runtime manifest row is emitted, with [dispatch] saying whether the
    candidate's provider or client was invoked or the walk refused the
    candidate first. It does not change candidate selection or the final
    error; verifier callers use it to learn whether an attempt on the one
    runtime a [Tool_verdict] turn dispatches failed retryably.

    [on_runtime_lane_terminal_error] observes the candidate error the walk
    returns as the lane's error, with the candidate that produced it, once per
    walk that ends on a candidate's error.

    [on_request_attribution] reports what an official-client lane could
    observe of its own model input, together with the tool list that lane
    sent. It fires once per attempt on the Codex, Antigravity and Claude Code
    lanes, which assemble the wire inside the client and therefore never reach
    [on_request_wire_observation]. The Agent Core lane does not use it: its
    own serializer produced the bytes, so it reports through
    [on_request_wire_observation] instead.

    [transmitted] carries the history only when the lane started the
    conversation. On a resume it says the client's session holds the input, so
    the caller records a gap rather than attributing a local list the client
    never re-sent. [tools] is the lane's own list, not the one passed to
    [run_named]: the Claude Code lane sends [[]] to a target that declares no
    tool support. *)

type attempt_inference_policy =
  { attempt_enable_thinking : bool option
  ; attempt_preserve_thinking : bool option
  }

module For_testing : sig
  val run_result_answered : Runtime_agent.run_result -> bool
  (** Whether a successful attempt heard from its candidate: [false] for an
      attempt that yielded before any provider turn completed, which clears no
      failure evidence (RFC-0458 §3.4). *)

  val make_deferred_runtime_lane :
    assignment_id:string ->
    failed_runtime_id:string ->
    next_runtime_id:string ->
    later_runtime_ids:string list ->
    failure:Agent_core.Error.t ->
    deferred_runtime_lane

  type provider_attempt_outcomes

  val produced_checkpoint : provider_attempt_outcomes -> Agent_core.Checkpoint.t option

  val project_provider_attempt_result :
    ?checkpoint_after:Agent_core.Checkpoint.t ->
    replay_prefix_projection:Keeper_replay_prefix.projection ->
    (Runtime_agent.run_result, Agent_core.Error.t) result ->
    provider_attempt_outcomes

  val canonical_checkpoint_sink :
    replay_prefix_projection:Keeper_replay_prefix.projection ->
    Agent_core.Agent.checkpoint_sink -> Agent_core.Agent.checkpoint_sink

  val provider_result :
    provider_attempt_outcomes ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val turn_result :
    provider_attempt_outcomes ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val checkpoint_after_attempt :
    ?agent_before_attempt:Agent_core.Agent.t ->
    ?session_id:string -> ?working_context:Yojson.Safe.t ->
    ?agent_ref:Agent_core.Agent.t option ref ->
    Agent_core.Agent.t option ->
    Agent_core.Checkpoint.t option

  val success_selected_model_raw : Runtime_candidate.t -> string option

  val apply_accept :
    runtime_id:string ->
    accept:(Agent_core.Types.api_response -> bool) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val apply_official_client_accept :
    runtime_id:string ->
    accept:(Agent_core.Types.api_response -> bool) ->
    terminal_effect_state:(unit -> Keeper_tools_agent_core.terminal_effect_state) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val log_modality_reroute :
    keeper_name:string ->
    assignment_id:string ->
    first_candidate_id:string ->
    Runtime.t Runtime_agent.reroute_decision ->
    unit
  (** On [Reroute], logs a WARN naming the lane head, the lane candidate the
      image turn starts from, and [assignment_id]. Logs nothing otherwise (the
      caller reports the degrade). *)

  val modality_reroute_candidates :
    now:float ->
    walk:walk_start ->
    deferred_runtime_lane:deferred_runtime_lane option ->
    first_candidate:Runtime.t ->
    remaining_runtimes:Runtime.t list ->
    Runtime.t list

  val attempt_runtimes_for_turn :
    media_walk:Runtime.t list ->
    lane:Runtime.t list ->
    Runtime.t list

  val lane_modality_reroute_decision :
    checkpoint_messages:Agent_core.Types.message list ->
    initial_messages:Agent_core.Types.message list ->
    goal_blocks:Agent_core.Types.content_block list ->
    first_candidate:Runtime.t ->
    candidates:Runtime.t list ->
    Runtime.t Runtime_agent.reroute_decision

  val dedupe_runtimes_preserve_order : Runtime.t list -> Runtime.t list
  val resolve_runtime_candidates :
    string list ->
    (Runtime.t list, Agent_core.Error.t) result

  val resolve_runtime_candidate_for_attempt :
    ?on_missing:(unit -> unit) ->
    string ->
    (Runtime.t, Agent_core.Error.t) result

  val selected_runtime_result :
    ?official_client_settlement:Keeper_official_client_session_store.t ->
    Runtime.t ->
    lane_attempt_index:int ->
    (Runtime_agent.run_result, Agent_core.Error.t) result ->
    (named_run_result, Agent_core.Error.t) result

  val media_degrade_manifest_decision :
    runtime_id:string -> (string * int) list -> Yojson.Safe.t

  val project_input_for_attempt :
    project_images:
      (mode:Keeper_vision_ingest.mode ->
       Agent_core.Types.content_block list -> Keeper_vision_ingest.image_projection) ->
    keeper_name:string ->
    emit_runtime_manifest:
      (?status:string ->
      ?decision:Yojson.Safe.t ->
      Keeper_runtime_manifest.event_kind ->
      unit) ->
    goal_blocks:Agent_core.Types.content_block list option ->
    initial_messages:Agent_core.Types.message list ->
    agent_core_checkpoint:Agent_core.Checkpoint.t option ->
    runtime_id:string ->
    Runtime.t ->
    attempt_input
  (** The per-attempt RFC-0265 decision for one resolved candidate: unchanged
      when the runtime admits the turn's modalities, otherwise image readings/references
      precede the strip of other unsupported media, with manifest rows through
      [emit_runtime_manifest]. [Reroute] has no producer here because the
      decision is taken with no reroute candidates. *)

  val attempt_inference_policy :
    runtime_id:string ->
    fallback_enable_thinking:bool option ->
    unit ->
    attempt_inference_policy

  val attempt_runtime_candidates :
    ?pre_tool_rejects:Keeper_official_client_host.rejected_tool_call list ref ->
    ?allow_retry:
      (runtime_id:string -> attempt:int -> Agent_core.Error.t -> bool) ->
    ?allow_accept_no_progress_retry:
      (runtime_id:string -> attempt:int -> Agent_core.Error.t -> bool) ->
    ?retry_deferral:runtime_retry_deferral ->
    ?tool_results_saved:(unit -> bool) ->
    ?on_attempt_error:
      (runtime_id:string ->
      attempt:int ->
      dispatch:Keeper_attempt_dispatch.t ->
      Agent_core.Error.t ->
      unit) ->
    ?on_lane_terminal_error:(lane_terminal_error -> unit) ->
    ?provider_answered:('result -> bool) ->
    ?quota_scope_of:('candidate -> Runtime_quota_window.scope option) ->
    ?model_of:('candidate -> string option) ->
    ?candidate_backpressure_of:('candidate -> Runtime_candidate_backpressure.candidate option) ->
    ?candidate_dispatchable:('candidate -> bool) ->
    walk_owner:walk_owner ->
    runtime_id:string ->
    runtime_id_of:('candidate -> string) ->
    emit_runtime_manifest:
      (?status:string ->
      ?decision:Yojson.Safe.t ->
      Keeper_runtime_manifest.event_kind ->
      unit) ->
    run_attempt:
      (idx:int ->
      runtime_id:string ->
      'candidate ->
      ('result, Agent_core.Error.t) result
      * Agent_core.Checkpoint.t option
      * Keeper_provider_attempt_effect.t
      * Keeper_attempt_dispatch.t) ->
    'candidate list ->
    ('result, Agent_core.Error.t) result
  (** [tool_results_saved] reads whether the attempt that just failed saved
      tool results; without it the walk reads [false]. A [retry_deferral] with
      [Resume_operation_checkpoint] defers the last candidate to itself only
      when it reads [true] and the failure's route passes with time. *)

  val observe_checkpoint_stage :
    Keeper_turn_driver_try_provider.checkpoint_progress Atomic.t ->
    Agent_core.Agent.checkpoint_stage ->
    unit

  val observing_checkpoint_sink :
    Keeper_turn_driver_try_provider.checkpoint_progress Atomic.t ->
    Agent_core.Agent.checkpoint_sink option ->
    Agent_core.Agent.checkpoint_sink

  val observe_checkpoint_saved :
    Keeper_turn_driver_try_provider.checkpoint_progress Atomic.t ->
    Agent_core.Agent.checkpoint_stage ->
    unit

  val same_run_retry_allowed :
    Keeper_turn_driver_try_provider.checkpoint_progress Atomic.t -> bool

  val tool_results_saved :
    Keeper_turn_driver_try_provider.checkpoint_progress Atomic.t -> bool

  val accept_no_progress_should_try_next : Agent_core.Error.t -> bool

end
