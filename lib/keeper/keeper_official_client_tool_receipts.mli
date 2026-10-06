(** Bind an official client's dynamic-tool block to its exact host
    invocation, and report the committed execution id for that block.

    Every official client (Codex, Claude Code, Antigravity, Muse) opens one
    stream block per MASC tool call, runs the call through
    {!Keeper_official_client_host.dynamic_tools}, then closes the block. Calls
    are keyed by the producer's call id, so concurrent calls with distinct ids
    each keep their own block. Native tools have no host execution receipt. *)

type t

type delivery =
  | Immediate
      (** Every block reaches the stream as soon as the producer opens it. *)
  | Held_until_released
      (** The producer holds blocks opened before its message starts.
          Receipts committed before {!release} wait for it, so none names a
          block the stream has not seen. *)

val create :
  delivery:delivery ->
  notify:(block_index:int -> tool_call_id:string -> execution_id:Ids.Execution_id.t -> unit) ->
  t

val start : t -> call_id:string -> block_index:int -> unit
(** The producer opened [block_index] for [call_id]. A second open of a call
    id that is still active is a producer protocol violation and raises. *)

val finish : t -> call_id:string -> unit
(** The producer closed the block of [call_id]. Raises when that call id has
    no open block. *)

val release : t -> unit
(** The held blocks reached the stream. Delivers the receipts that waited
    for them, in commit order; later receipts are delivered at commit. A
    second call does nothing. *)

val hooks : t -> Agent_core.Hooks.hooks -> Agent_core.Hooks.hooks
(** The pre-hook binds the invocation before execution. The post-hook reports
    only a committed receipt, before the event bus consumes its join, including
    when the original hook is cancelled after committing the log row. *)
