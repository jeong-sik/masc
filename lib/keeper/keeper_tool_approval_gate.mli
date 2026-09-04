(** Wires the approval policy, the wait, and the chat stream into the two
    pieces AGENT_CORE needs to hold a tool call for an operator.

    A gate takes two of them, and each is useless alone:

    - a [pre_tool_use] hook, which decides {i whether} to ask — from
      {!Keeper_tool_approval_policy}
    - a [tool_approval] callback, which {i does} the asking — handing the
      question to [publish] and parking on {!Keeper_tool_approval_registry}
      until an answer or the timeout

    [publish] takes an event rather than a stream so the caller decides where
    it goes: the chat handler already owns one path for the events it sends a
    reader, and a second stream would need a fiber to drain it into the
    first.

    Built together here so a caller cannot install one without the other. A
    hook that asks with no callback to answer rejects every call it stops; a
    callback with no hook is never reached. *)

type t =
  { pre_tool_use : Agent_core.Hooks.hook
  ; tool_approval : Agent_core.Hooks.tool_approval_callback
  ; composition_plan_index : Keeper_tool_composition_plan_index.t
  }

val create :
  registry:Keeper_tool_approval_registry.t ->
  late_approvals:Keeper_late_approval.t ->
  publish:(Keeper_chat_events.keeper_chat_event -> unit) ->
  redact_text:(string -> string) ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  keeper_name:string ->
  timeout_sec:float ->
  t
(** A gate for one keeper's turn on one chat stream. Its composition plan
    index has exactly the same lifetime, so another turn cannot overwrite the
    plan this gate judges.

    [redact_text] is the turn's secret redaction, applied to the arguments,
    question and reason of every [Tool_approval_requested] before it is
    published: the bus feeds the canonical journal (RFC-0412), so what is
    published is what is kept.

    [timeout_sec] bounds how long a call waits. It is required: a wait with no
    bound parks the turn for the life of the process when nobody is watching,
    and how long an operator gets is not something this module can know.

    A wait that ends without an answer — timed out, or displaced by a second
    call claiming the same id — denies the call. Denial goes back to the model
    as a failure it can respond to, so the turn continues and the keeper can
    say it was refused. Admitting on silence would run the call this exists to
    hold.

    [late_approvals] bridges one gap in that: a timed-out ask is recorded
    there, and an operator's answer arriving after the wait is gone settles
    the identical retried call once instead of being dropped. The callback
    consults it before opening a new wait, so a remembered answer still
    publishes the requested/settled pair — the stream shows the question was
    raised and settled from the operator's earlier word. The memory is
    age-bounded ({!Keeper_late_approval.ttl_sec}): an answer too old to still
    be the operator's moment is reaped, and the call is asked about again. *)
