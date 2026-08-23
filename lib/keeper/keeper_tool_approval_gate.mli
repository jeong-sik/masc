(** Wires the approval policy, the wait, and the chat stream into the two
    pieces AGENT_CORE needs to hold a tool call for an operator.

    A gate takes two of them, and each is useless alone:

    - a [pre_tool_use] hook, which decides {i whether} to ask — from
      {!Keeper_tool_approval_policy}
    - a [tool_approval] callback, which {i does} the asking — publishing the
      question to the chat stream and parking on
      {!Keeper_tool_approval_registry} until an answer or the timeout

    Built together here so a caller cannot install one without the other. A
    hook that asks with no callback to answer rejects every call it stops; a
    callback with no hook is never reached. *)

type t =
  { pre_tool_use : Agent_core.Hooks.hook
  ; tool_approval : Agent_core.Hooks.tool_approval_callback
  }

val create :
  registry:Keeper_tool_approval_registry.t ->
  events:Keeper_chat_events.keeper_chat_event Eio.Stream.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  keeper_name:string ->
  timeout_sec:float ->
  t
(** A gate for one keeper's turn on one chat stream.

    [timeout_sec] bounds how long a call waits. It is required: a wait with no
    bound parks the turn for the life of the process when nobody is watching,
    and how long an operator gets is not something this module can know.

    A wait that ends without an answer — timed out, or displaced by a second
    call claiming the same id — denies the call. Denial goes back to the model
    as a failure it can respond to, so the turn continues and the keeper can
    say it was refused. Admitting on silence would run the call this exists to
    hold. *)
