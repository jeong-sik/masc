(** Capture causal authority at dispatch intent, record facts at actual results.
    All durable mutations use the original canonical Skill event ledger. *)
type t
type error =
  | Delivery_failed of Keeper_composition_result_delivery.error
  | Ledger_failed of Keeper_skill_activation_ledger.store_error
  | Invalid_evidence of string
val create : config:Workspace.config -> context:Keeper_skill_activation_recorder.t -> t
val clear : t -> unit
(** A new Keeper turn/runtime attempt drops both active and in-flight authority. *)
val begin_handoff : t -> unit
(** Clear earlier active handoffs while preserving causality already captured
    by an in-flight dispatch in this physical attempt. *)
val record_delivery : t -> Keeper_composition_result_delivery.observation ->
  (Keeper_skill_async_delivery.t option, error) result
(** [Some] is an actual durable delivery. An attempt that changes during I/O
    keeps that original fact without publishing it as current authority.
    [None] means the completed run has no admitted original child. *)
val sdk_hook : t -> on_error:(error -> unit) -> Agent_core.Hooks.hook_event -> Agent_core.Hooks.hook_decision
(** PreToolUse captures authority, but is not an action fact. Only PostToolUse
    records the actual handler result. Validation failure drops that intent. *)
val native_started : t -> runtime_id:string -> official_turn:int ->
  identity:Runtime_native_tools.action_identity -> tool_name:string -> (int, error) result
val error_to_string : error -> string
