(** Invocation-local join of private input evidence and runtime-admitted native
    task ownership. Public task transport data cannot enter this boundary. *)

type evidence = private
  | Explicit_group of Runtime_claude_input_attribution.group
  | Response_inherited of Runtime_claude_input_attribution.group
  | Command_inherited of Runtime_claude_input_attribution.command_witness

type bound = private
  { ticket : Runtime_claude_input_attribution.ticket
  ; evidence : evidence
  ; observation : Runtime_claude_code.native_task_observation
  }

type rejection =
  | Missing_ticket
  | Conflicting_invocation
  | Foreign_session
  | Foreign_invocation
  | Missing_assistant_evidence
  | Unattributed_assistant
  | Rejected_assistant of Runtime_claude_input_attribution.rejection
  | Input_not_in_group
  | Conflicting_assistant_evidence

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
val rejection_to_string : rejection -> string
