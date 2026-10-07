(** Durable native calls belonging to one direct Keeper operation. This
    adapter is for the outer native dispatch only. Nested Agent calls inherit
    Core's ambient child scope and must not receive an explicit store. *)

type binding =
  { base_path : string
  ; keeper_name : string
  ; operation_id : Keeper_chat_operation.Operation_id.t
  ; execution_digest : string
  ; session_dir : string
  ; session_id : string
  }

type input =
  | New_input of
      { blocks : Agent_core.Types.content_block list
      ; metadata : Agent_core.Types.metadata
      }
  | Continue_from_checkpoint

type resumed

type admission =
  | No_pending
  | Resume of resumed
  | Terminal_pending of
      Keeper_native_call.t * Agent_core.Agent.execution_terminal_disposition

val load : binding:binding -> (admission, string) result
(** Read Owner authority and exact retained checkpoints. An Active Owner call
    whose Core journal already terminated is reconciled to an unacknowledged
    terminal receipt, without fabricating its lost response. A terminal pending
    call is not a restartable provider attempt. No canonical-history fallback
    is used for missing or inconsistent retained evidence. *)

val runtime_id : resumed -> string
val system_prompt : resumed -> string
val checkpoint : resumed -> Agent_core.Checkpoint.t
val initial_messages : resumed -> Agent_core.Types.message list
val input : resumed -> input

type prepared

type retired_history_cut

val authorize_incomplete_response_cut :
  binding:binding -> checkpoint:Agent_core.Checkpoint.t -> unit ->
  (retired_history_cut, string) result
(** For the host's typed [Retry_without_thinking] decision only. Witness that
    this checkpoint removes exactly the last incomplete Assistant message
    from the current Retire receipt, preserving every earlier message and
    every other checkpoint field except its observation timestamp. The
    removed message cannot contain a settled ToolResult. This is neither
    acknowledgement nor an execution-journal mutation. *)

val prepare :
  binding:binding -> runtime_id:string -> config:Runtime_agent.config ->
  agent_core_checkpoint:Agent_core.Checkpoint.t option -> input:input ->
  agent_ref:Agent_core.Agent.t option ref -> ?retired_history_cut:retired_history_cut ->
  unit -> (prepared, string) result
(** Call immediately before each actual native Agent API invocation. Active
    scopes restore their exact seed/input and checkpoint. A known Retire
    receipt is atomically replaced only when the next scope publishes its
    locator; unknown effects cannot be replaced. The host must select the
    saved runtime before preparing a recovered call. Recovery validates its
    runtime ID, Agent name and model; this receipt grants no credential or
    endpoint authority. Existing runtime materialization owns those checks.
    Replacing a retired call preserves every canonically settled root
    ToolResult. After Tool-attempt admission it also preserves its exact
    transcript; the sole cut exception is an exact, still-current
    [retired_history_cut] witness. Provider-only calls admit the host's existing
    media projection when no Tool attempt was admitted. *)

val config : prepared -> Runtime_agent.config
val prepared_checkpoint : prepared -> Agent_core.Checkpoint.t option
val prepared_input : prepared -> input
val binding_effect_observation : binding:binding -> Keeper_provider_attempt_effect.t
val effect_observation : prepared -> Keeper_provider_attempt_effect.t
(** Owner/journal read failure, an active scope, an unknown-effect terminal,
    or a retained checkpoint missing canonically settled ToolResults keeps
    provider fallback fenced. A known Retire receipt permits the existing
    checkpoint-based continuation path; it does not claim zero historical
    tool effects. *)

val acknowledge : binding:binding -> (unit, string) result
(** Only after the host durably accepts this call's returned checkpoint or
    turn outcome. Retire receipts may be acknowledged; active/unknown calls
    are retained and rejected. Normal operation settlement can perform the
    same acknowledgement within its own Owner transaction. *)
