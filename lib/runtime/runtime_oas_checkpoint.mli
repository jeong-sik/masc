(** Runtime_oas_checkpoint — lifecycle, checkpoint, and
    idle-detail helpers extracted from {!Runtime_agent}.

    Keeps side-effecting run helpers separate from the main
    build / resume / run orchestration so the orchestration
    module stays focused on Eio fiber composition.

    No internal helpers are hidden; the .mli pins each entry
    point's contract so a future refactor of the OAS Agent
    surface (Provider / Checkpoint / Types renames) fails here
    instead of at every call site in {!Runtime_agent}. *)

val publish_lifecycle :
  Agent_sdk.Event_bus.t ->
  name:string ->
  event:string ->
  detail:string ->
  ?error:string ->
  ?session_id:string ->
  ?status:string ->
  ?attrs:(string * Yojson.Safe.t) list ->
  unit ->
  unit
(** Publish a [Custom "masc.oas_worker.<event>"] event on the
    process-wide [Masc_event_bus]. The first argument is
    accepted but **ignored** — the function looks up the bus via
    [Masc_event_bus.get ()] internally; the parameter is kept
    for backwards-compatibility with callers that already thread
    the bus through, and for symmetry with sibling lifecycle
    publishers that do consume their bus argument.

    Optional [error] / [session_id] / [status] fields are
    included in the payload only when [Some] and non-empty
    after trim — empty strings are dropped to keep the JSON
    payload skinny for downstream SSE consumers. [attrs] carries
    non-sensitive structured runtime metadata such as provider
    kind, model, and endpoint path. *)

val persist_checkpoint :
  dir:string ->
  session_id:string ->
  Agent_sdk.Checkpoint.t ->
  (unit, string) result
(** Serialise [ckpt] via [Agent_sdk.Checkpoint.to_string] and write it
    atomically (tmp → fsync → rename) to [<dir>/<session_id>.json].
    Returns [Error msg] on I/O failure instead of raising.
    The parent [dir] is created via [Fs_compat.mkdir_p] before
    the write. *)

val build_checkpoint :
  session_id:string ->
  ?checkpoint_sidecar:Yojson.Safe.t ->
  Agent_sdk.Agent.t ->
  Agent_sdk.Checkpoint.t
(** Build an [Agent_sdk.Checkpoint.t] for [agent].

    When [checkpoint_sidecar] is omitted, delegates to
    [Agent_sdk.Agent.checkpoint ~session_id agent] (the SDK's own
    checkpoint capture).

    When [checkpoint_sidecar] is supplied, builds the checkpoint
    via [Agent_sdk.Agent_checkpoint.build_checkpoint] threading the
    sidecar JSON through as the [working_context]; this path is
    used when masc wants to attach extra worker-side state
    that the SDK's default capture does not include. *)

val partial_response_of_stop :
  session_id:string ->
  text:string ->
  Agent_sdk.Types.api_response
(** Synthesise an [Agent_sdk.Types.api_response] for the early-stop
    case (e.g. operator-side cancel before the model finishes).
    [stop_reason = EndTurn], single [Text] content block, no
    usage / telemetry. The emitted response model is the neutral [runtime]
    lane; OAS owns concrete provider/model identity. *)

val enrich_idle_detail :
  string ->
  Agent_sdk.Types.message list ->
  string
(** Enrich an [Agent_sdk.Error.to_string] detail string with the name
    of the most recently called tool when the detail starts
    with ["Idle detected"]. For all other detail strings the
    input is returned unchanged.

    The "most recently called tool" is projected through
    [Agent_sdk.Canonical_tool.tool_call_of_block] from the most recent
    [Assistant] message; when no such block exists the bare detail is returned.

    Exposed at module level so the test suite can exercise it
    independently of the network-bound [run] function. *)
