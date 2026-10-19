(** Read pixels into the calling model without a vision provider sub-call.
    Paths use the ordinary Keeper sandbox boundary; artifact handles resolve
    only inside that Keeper's verified image store. The model-facing transport
    owns image capability admission for its materialized runtime snapshot. *)
val handle :
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  unit ->
  Keeper_tool_execution.t

val admission_hook : accepts_image_input:bool -> Agent_core.Hooks.hook
(** Reject before execution on a text-only attempt. The caller captures the
    selected runtime's capability once; the hook also covers deferred loading. *)
