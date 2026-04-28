(** Dashboard_operator_judge — periodic LLM-driven room judgment loop.

    Runs as an Eio daemon fiber per [base_path]: every
    [Env_config.Operator.judge_interval_sec], it asks an operator-judge
    keeper to evaluate room health using freshly built facts, then
    caches the verdict (and "is the judge online?" status) for HTTP
    consumption.

    The internal mutable per-base-path state, lock helpers, env-knob
    accessors, prompt construction, parsing, refresh loop, and backoff
    accounting are all hidden — the public surface is [start] (daemon
    spawn) plus [runtime_status] (snapshot read). *)

(** Read-only snapshot of judge runtime state, returned by
    {!runtime_status} and serialized into operator pending-confirm
    payloads. All fields are read externally. *)
type runtime_snapshot = {
  enabled : bool;
  judge_online : bool;
  refreshing : bool;
  generated_at : string option;
  expires_at : string option;
  model_used : string option;
  keeper_name : string;
  last_error : string option;
}

val runtime_status : string -> runtime_snapshot
(** Snapshot the current judge state for [base_path]. Creates an empty
    state on first call, so always returns a well-defined record. *)

val start :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:Coord.config ->
  masc_tools:Types_core.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> bool * string) ->
  build_facts:(unit -> Yojson.Safe.t) ->
  unit ->
  unit
(** Spawn the judge daemon for [config.base_path] iff
    [Env_config.Operator.judge_enabled] and not already running.
    Backoff doubles up to 5x and caps at 300s when local cascade slots
    are saturated. Idempotent: subsequent calls are no-ops. *)
