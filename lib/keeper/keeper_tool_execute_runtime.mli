(** Keeper_tool_execute_runtime — owner of the typed Shell IR execution
    pipeline and its public Keeper execution boundary. *)

val handle_tool_execute :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  ?shell_tool_runtime:Keeper_shell_tool_command.runtime ->
    (** The calling turn's narrow tool runtime. Present on a real turn, absent
        on replay — present is what lets a shell-line [masc] stage reach the
        tool runtime without making Execute depend back on its dispatcher;
        absent keeps replay process-only. *)
  args:Yojson.Safe.t ->
  unit ->
  string

val gate_operation : string
(** The Gate operation name this runtime submits under. Shared with the replay
    path so an approved execute is recognised rather than skipped. *)

val replay_args_of_gate_input : Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Recover the approved tool arguments from the stored Gate input.

    The Gate request wraps the arguments with execution context rather than
    re-encoding them, so the approved arguments are returned verbatim —
    including the [cwd] the submitting turn resolved and upserted into them.
    Replaying that [cwd] is the point: the approval describes one working
    directory, and re-deriving the current turn's default would execute
    somewhere the operator never saw.

    The envelope's sibling [cwd]/[sandbox_profile]/[sandbox_target] fields
    stay behind. The handler re-derives the sandbox from the current turn and
    rebuilds the envelope, so a sandbox that moved between approval and replay
    produces a different canonical input and fails the match rather than
    executing under a profile the approval did not describe. *)

val handle_tool_execute_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  ?shell_tool_runtime:Keeper_shell_tool_command.runtime ->
    (** The calling turn's narrow tool runtime. Present on a real turn, absent
        on replay — present is what lets a shell-line [masc] stage reach the
        tool runtime without making Execute depend back on its dispatcher;
        absent keeps replay process-only. *)
  args:Yojson.Safe.t ->
  unit ->
  Keeper_tool_execution.t

module For_testing : sig
  (* Test seam: when set, [handle_tool_execute_typed] routes its dispatch
     through this override instead of the real shell dispatch, so tests can
     drive each rejected-dispatch branch through the real production wiring
     (stream start -> dispatch -> stream end) without spawning a process. *)
  val dispatch_override :
    (unit ->
     ( Masc_exec.Exec_dispatch.dispatch_result
     , Keeper_tooling.Execute_shell_ir.dispatch_error )
     result)
    option
    ref

  val elapsed_duration_ms : start_time:float -> end_time:float -> int
  val model_execute_location_fields :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    args:Yojson.Safe.t ->
    cwd:string ->
    (string * Yojson.Safe.t) list

  val redact_execute_output :
    base_path:string ->
    keeper_name:string ->
    stdout:string ->
    stderr:string ->
    string * string * string

  val redact_execute_output_with_additional_secret_files :
    additional_secret_files:string list ->
    base_path:string ->
    keeper_name:string ->
    stdout:string ->
    stderr:string ->
    string * string * string
end
