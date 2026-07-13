(** Dashboard_operator_judge — periodic LLM-driven workspace judgment loop.

    Runs as an Eio daemon fiber per [base_path]: every
    [Env_config.Operator.judge_interval_sec], it asks an operator-judge
    keeper to evaluate workspace health using freshly built facts, then
    caches the verdict (and "is the judge online?" status) for HTTP
    consumption.

    The internal mutable per-base-path state, lock helpers, env-knob
    accessors, prompt construction, parsing, and refresh loop are all hidden —
    the public surface is [start] (daemon
    spawn) plus [runtime_status] (snapshot read). *)

(** Read-only snapshot of judge runtime state, returned by
    {!runtime_status} and serialized into operator pending-confirm
    payloads. All fields are read externally. [model_used]
    is retained for compatibility and redacted to [None] on
    public snapshots. *)
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
  config:Workspace.config ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.result) ->
  build_facts:(unit -> Yojson.Safe.t) ->
  unit ->
  unit
(** Spawn the judge daemon for [config.base_path] iff
    [Env_config.Operator.judge_enabled] and not already running.
    Provider availability is observed by attempting the configured LLM call;
    no local capacity heuristic suppresses a cycle. Idempotent: subsequent
    calls are no-ops. *)

val register_record_operator_judgment :
  (Workspace.config ->
   surface:string ->
   target_type_str:string ->
   target_id:string option ->
   summary:string ->
   confidence:float ->
   ?model_name:string ->
   ?recommended_action:Yojson.Safe.t ->
   evidence_refs:string list ->
   disagreement_with_truth:bool ->
   generated_at:string ->
   generated_at_unix:float ->
   fresh_until:string ->
   fresh_until_unix:float ->
   keeper_name:string ->
   unit ->
   unit) ->
  unit
