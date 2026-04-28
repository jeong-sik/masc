(** Oas_worker_exec_checkpoint — lifecycle, checkpoint, and
    idle-detail helpers extracted from {!Oas_worker_exec}.

    Keeps side-effecting run helpers separate from the main
    build / resume / run orchestration so the orchestration
    module stays focused on Eio fiber composition.

    No internal helpers are hidden; the .mli pins each entry
    point's contract so a future refactor of the OAS Agent
    surface (Provider / Checkpoint / Types renames) fails here
    instead of at every call site in {!Oas_worker_exec}. *)

val publish_lifecycle :
  Oas.Event_bus.t ->
  name:string ->
  event:string ->
  detail:string ->
  ?error:string ->
  ?session_id:string ->
  ?status:string ->
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
    payload skinny for downstream SSE consumers. *)

val persist_checkpoint :
  dir:string ->
  session_id:string ->
  Oas.Checkpoint.t ->
  unit
(** Serialise [ckpt] via [Oas.Checkpoint.to_string] and write it
    atomically to [<dir>/<session_id>.json]. The parent [dir]
    is created via [Fs_compat.mkdir_p] before the write — the
    function never raises on a missing directory. *)

val build_checkpoint :
  session_id:string ->
  ?checkpoint_sidecar:Yojson.Safe.t ->
  Oas.Agent.t ->
  Oas.Checkpoint.t
(** Build an [Oas.Checkpoint.t] for [agent].

    When [checkpoint_sidecar] is omitted, delegates to
    [Oas.Agent.checkpoint ~session_id agent] (the SDK's own
    checkpoint capture).

    When [checkpoint_sidecar] is supplied, builds the checkpoint
    via [Oas.Agent_checkpoint.build_checkpoint] threading the
    sidecar JSON through as the [working_context]; this path is
    used when masc-mcp wants to attach extra worker-side state
    that the SDK's default capture does not include. *)

val partial_response_of_stop :
  session_id:string ->
  model_id:string ->
  text:string ->
  Oas.Types.api_response
(** Synthesise an [Oas.Types.api_response] for the early-stop
    case (e.g. operator-side cancel before the model finishes).
    [stop_reason = EndTurn], single [Text] content block, no
    usage / telemetry. The shape lets downstream code treat
    operator-stop and model-stop uniformly. *)

val enrich_idle_detail :
  string ->
  Oas.Types.message list ->
  string
(** Enrich an [Oas.Error.to_string] detail string with the name
    of the most recently called tool when the detail starts
    with ["Idle detected"]. For all other detail strings the
    input is returned unchanged.

    The "most recently called tool" is the last
    [Oas.Types.ToolUse { name }] block in the most recent
    [Assistant] message; when no such block exists the bare
    detail is returned.

    Exposed at module level so the test suite can exercise it
    independently of the network-bound [run] function. *)
