(** Invocation-local join of private input evidence and runtime-admitted native
    ownership. Public task/child transport data cannot enter this boundary. *)

type evidence = private
  | Explicit_group of Runtime_claude_input_attribution.group
  | Response_inherited of Runtime_claude_input_attribution.group
  | Command_inherited of Runtime_claude_input_attribution.command_witness

type bound = private
  { ticket : Runtime_claude_input_attribution.ticket
  ; evidence : evidence
  ; observation : Runtime_claude_code.native_task_observation
  }

type bound_parent = private
  { ticket : Runtime_claude_input_attribution.ticket
  ; evidence : evidence
  ; parent : Runtime_claude_code.native_agent_parent_witness
  }
(** Original native Agent occurrence joined to its exact invocation input
    evidence. This certifies neither a child body's authenticity/parent pairing,
    Task/run ownership, current call authority, nor publication/persistence. *)

type bound_child = private
  { parent_input : bound_parent
  ; content : Runtime_claude_code.complete_child_content
  }
(** Actual complete-frame child provenance joined to the original native Agent
    call's input evidence. This does not prove that child consumed that input
    group, mint Task/run ownership, or authorize publication/persistence. *)

type rejection =
  | Missing_ticket
  | Conflicting_invocation
  | Foreign_session
  | Foreign_invocation
  | Unknown_parent
  | Conflicting_parent_provenance
  | Missing_assistant_evidence
  | Unattributed_assistant
  | Rejected_assistant of Runtime_claude_input_attribution.rejection
  | Input_not_in_group
  | Conflicting_assistant_evidence

type child_observation = private
  | Child_bound of bound_child
  | Child_rejected of
      { content : Runtime_claude_code.complete_child_content
      ; reason : rejection
      }
(** A refusal retains the actual child content and its unknown/foreign
    provenance; it must not be displayed as a root answer or a bound child. *)

type t

val create : unit -> t
(** Create separately around each actual runtime invocation, including a new
    invocation inside the same routed candidate. No global/latest ticket. *)
val observe_input : t -> Runtime_claude_input_attribution.observation -> unit
(** Prepared captures the ticket. Only an exact complete Assistant envelope
    with private frame attribution can bind its native owners. Partial/result
    frames and accumulated phase are not substitutes. First missing/rejected
    envelope evidence cannot be upgraded retrospectively; conflicts quarantine
    subsequent bindings without changing previously emitted values. *)
val bind_task : t -> Runtime_claude_code.native_task_observation ->
  (bound, rejection) result
(** Keeps the original native occurrence's input across call closure and task
    run changes. The runtime owner's actual invocation ticket must match the
    observed Prepared ticket in receiver generation, session and client UUID.
    Foreign session/invocation is refused before owner-cache access, preserving
    subsequent bindings of the current invocation's owner. Failed first binding
    is retained for that exact invocation/occurrence, including before Prepared;
    another invocation reusing the SDK IDs has a separate cache identity. This
    neither admits raw frames nor changes model content, effects or task phase.
    Root result does not erase historical bindings; this module does not keep
    the current one-result runtime receiver alive. *)
val bind_parent : t -> Runtime_claude_code.native_agent_parent_witness ->
  (bound_parent, rejection) result
(** Uses the same exact invocation/occurrence key, foreign-invocation guard and
    frozen failed-first evidence cache as [bind_task]. Parent-before-task and
    task-before-parent therefore share the same original input decision.
    The witness may precede task registration or follow native return. A
    separately supplied body must validate its literal parent ID; this API
    receives no body and cannot bind or publish one. [bind_child] separately
    requires the runtime's private complete-content provenance. *)
val bind_child : t -> Runtime_claude_code.complete_child_content ->
  (bound_child, rejection) result
(** Checks the child's actual invocation and literal parent against its private
    occurrence, then uses [bind_parent]'s exact shared failed-first authority.
    [Unknown_parent] retains uncertainty without fabricating an owner. No body
    matching, current-input inference, or retroactive parent upgrade occurs. *)
val observe_child : t -> Runtime_claude_code.complete_child_content -> child_observation
(** Seals the actual [bind_child] decision together with its actual private
    content. Callers cannot substitute a different refusal reason or body. *)
val rejection_to_string : rejection -> string
